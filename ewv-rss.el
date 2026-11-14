;;; ewv-rss.el --- RSS reader in a WebView2 view  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Windows counterpart of appine's RSS reader (`appine-rss'):
;;
;;   (setq ewv-rss-path "~/.emacs.d/elfeed/elfeed.org")
;;   M-x ewv-rss
;;
;; The subscriptions come from an elfeed-org file (or a directory of them):
;; headings are folders, a heading that is a link or a URL is a feed.  The
;; reader is one buffer covered by a webview showing rss.html: a sidebar with
;; the feed tree and unread counts, the article list, and the article itself.
;;
;; Emacs does the work; the page only displays.  Emacs fetches the feeds
;; (url.el), parses them (libxml), and keeps the articles with their read and
;; starred state in SQLite.  The two talk in web messages: the page posts
;; requests (`ewv-rss--on-message'), Emacs posts data back (`ewv-rss--post').
;; Feed content is untrusted HTML, so the page shows it only in a sandboxed
;; frame, and of what the page asks, Emacs opens nothing but http(s) links.
;;
;; The database has the schema of appine's (<data dir>/db/rss.sqlite), so
;; `ewv-rss-data-directory' can point at a copy of an "appine-rss" directory.
;;
;; Keys, in the page and (with the focus in Emacs) in the buffer:
;;   j/n k/p   next / previous article      s   star
;;   u         read / unread                o   open the original in ewv
;;   b         open in the default browser  r   fetch all feeds
;;   A         mark the whole list read     SPC scroll the article
;; In the buffer only: e edits the feed file, G reloads it, i moves the focus
;; into the page.  In the page only: Esc (or C-g) gives the focus back.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'let-alist)
(require 'dom)
(require 'xml)
(require 'url)
(require 'url-http)
(require 'ewv-browser)

(defgroup ewv-rss nil
  "RSS reader based on ewv."
  :group 'ewv
  :prefix "ewv-rss-")

(defcustom ewv-rss-path nil
  "The subscriptions: an elfeed-org file, or a directory of such files.
When nil, `ewv-rss' asks for it on its first run and saves the answer."
  :type '(choice (const :tag "Not set" nil) (file :tag "File or directory")))

(defcustom ewv-rss-data-directory
  (expand-file-name "ewv-rss" (or (getenv "LOCALAPPDATA") user-emacs-directory))
  "Where the articles are kept (db/rss.sqlite, and org_rss_data/ if mirrored).
The layout and the database schema are those of appine's \"appine-rss\"
directory."
  :type 'directory)

(defcustom ewv-rss-refresh-interval 900
  "Seconds between automatic fetches while the reader is open, or nil for none."
  :type '(choice (const :tag "Never" nil) natnum))

(defcustom ewv-rss-fetch-concurrency 6
  "How many feeds to download at the same time."
  :type 'natnum)

(defcustom ewv-rss-fetch-timeout 30
  "Seconds after which a feed that has not answered is given up."
  :type 'natnum)

(defcustom ewv-rss-list-limit 2000
  "The most articles shown for one feed or folder (the newest ones)."
  :type 'natnum)

(defcustom ewv-rss-org-mirror nil
  "Non-nil to also write every article to an Org file, as appine does.
The files are <data dir>/org_rss_data/<folder>/<feed>.org, one entry per
article, with its read and starred state in the property drawer."
  :type 'boolean)

(defconst ewv-rss--buffer-name "*ewv-rss*")

(cl-defstruct (ewv-rss-node (:constructor ewv-rss-node--make))
  id name url kind children parent)

(defvar ewv-rss--db nil "The open SQLite database, or nil.")
(defvar ewv-rss--tree nil "The top-level nodes shown in the sidebar.")
(defvar ewv-rss--nodes (make-hash-table :test #'equal) "Node id -> node.")
(defvar ewv-rss--feed-nodes (make-hash-table :test #'equal) "Feed URL -> its first node.")
(defvar ewv-rss--selected "unread" "Id of the node whose articles the page lists.")
(defvar ewv-rss--fetched nil "Non-nil once this reader has fetched the feeds.")

(defvar ewv-rss--queue nil "Feed URLs waiting to be downloaded.")
(defvar ewv-rss--active 0 "Number of downloads in flight.")
(defvar ewv-rss--total 0 "Number of feeds in the current fetch.")
(defvar ewv-rss--done 0 "Number of feeds finished in the current fetch.")
(defvar ewv-rss--new 0 "Number of new articles found by the current fetch.")
(defvar ewv-rss--failed nil "Feeds the current fetch could not get: (URL . REASON).")
(defvar ewv-rss--generation 0 "Bumped to make downloads of a closed reader void.")
(defvar ewv-rss--timer nil "The automatic refresh timer.")
(defvar ewv-rss--dates (make-hash-table :test #'equal) "Date string -> seconds.")

;;; The page

(defun ewv-rss--page-url ()
  (concat "file:///" (expand-file-name "rss.html" ewv-core--src-dir)))

(defun ewv-rss--webview ()
  "The id of the reader's webview, or nil when the reader is not open."
  (when-let* ((buffer (get-buffer ewv-rss--buffer-name)))
    (buffer-local-value 'ewv-browser--local-id buffer)))

(defun ewv-rss--post (type &rest props)
  "Send the page a message of TYPE with PROPS, a plist of JSON values."
  (when-let* ((id (ewv-rss--webview)))
    (ewv-native-webview-post-web-message
     id (ewv-core--json (cons :type (cons type props))))))

(defun ewv-rss--bool (value)
  (if value t :false))

;;; Subscriptions (elfeed-org)

(defun ewv-rss--parse-heading (text)
  "Return (NAME . URL) for the heading TEXT; URL is nil for a folder."
  (cond
   ((string-match "\\`\\[\\[\\([^]]+\\)\\]\\(?:\\[\\([^]]*\\)\\]\\)?\\]" text)
    (let ((url (match-string 1 text))
          (name (match-string 2 text)))
      (cons (if (or (null name) (string-empty-p name)) (ewv-rss--host url) name) url)))
   ((string-match "\\`https?://[^ \t]+" text)
    (let ((url (match-string 0 text)))
      (cons (ewv-rss--host url) url)))
   (t (cons text nil))))

(defun ewv-rss--host (url)
  (or (ignore-errors (url-host (url-generic-parse-url url))) url))

(defun ewv-rss--load-tree ()
  "Read `ewv-rss-path' into `ewv-rss--tree'."
  (let ((root (ewv-rss-node--make :id "root" :name "Subscriptions" :kind "group"))
        (files (if (file-directory-p ewv-rss-path)
                   (directory-files ewv-rss-path t "\\.org\\'")
                 (list ewv-rss-path)))
        (count 0))
    (clrhash ewv-rss--nodes)
    (clrhash ewv-rss--feed-nodes)
    (dolist (file files)
      ;; The stack holds the ancestors of the heading being read, deepest
      ;; first; ROOT, at its bottom, stands for depth 0.
      (let ((stack (list root)))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (re-search-forward "^\\(\\*+\\)[ \t]+\\(.*\\)$" nil t)
            (let* ((depth (length (match-string 1)))
                   (text (string-trim
                          (replace-regexp-in-string
                           "[ \t]+:[[:alnum:]_@#%:]+:[ \t]*\\'" "" (match-string 2)))))
              ;; "entry-title: REGEXP" headings are elfeed-org tagging rules.
              (unless (or (string-empty-p text) (string-prefix-p "entry-title:" text))
                (pcase-let* ((`(,name . ,url) (ewv-rss--parse-heading text))
                             (node (ewv-rss-node--make
                                    :id (format "n%d" (cl-incf count))
                                    :name name :url url
                                    :kind (if url "feed" "group"))))
                  (while (> (length stack) depth) (pop stack))
                  (let ((parent (car stack)))
                    (setf (ewv-rss-node-parent node) parent)
                    (setf (ewv-rss-node-children parent)
                          (nconc (ewv-rss-node-children parent) (list node))))
                  (push node stack)
                  (puthash (ewv-rss-node-id node) node ewv-rss--nodes)
                  (when (and url (not (gethash url ewv-rss--feed-nodes)))
                    (puthash url node ewv-rss--feed-nodes)))))))))
    (setq ewv-rss--tree
          (append (list (ewv-rss-node--make :id "unread" :name "Unread" :kind "unread")
                        (ewv-rss-node--make :id "starred" :name "Starred" :kind "starred"))
                  (ewv-rss-node-children root)))))

(defun ewv-rss--node-feeds (node)
  "The feed URLs of NODE and everything under it."
  (when node
    (delete-dups
     (append (and (ewv-rss-node-url node) (list (ewv-rss-node-url node)))
             (mapcan #'ewv-rss--node-feeds (ewv-rss-node-children node))))))

(defun ewv-rss--feed-name (url)
  (if-let* ((node (gethash url ewv-rss--feed-nodes)))
      (ewv-rss-node-name node)
    ""))

(defun ewv-rss--tree-json (nodes)
  (vconcat
   (mapcar (lambda (node)
             (list :id (ewv-rss-node-id node)
                   :name (ewv-rss-node-name node)
                   :kind (ewv-rss-node-kind node)
                   :children (ewv-rss--tree-json (ewv-rss-node-children node))))
           nodes)))

;;; Database

(defun ewv-rss--db ()
  "The article database, opened (and created) on first use."
  (or ewv-rss--db
      (progn
        (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
          (user-error "ewv-rss needs an Emacs built with SQLite support"))
        (let ((dir (expand-file-name "db" ewv-rss-data-directory)))
          (make-directory dir t)
          (let ((db (sqlite-open (expand-file-name "rss.sqlite" dir))))
            (sqlite-execute db "CREATE TABLE IF NOT EXISTS articles (
id TEXT PRIMARY KEY, feed_url TEXT, title TEXT, summary TEXT,
content TEXT, link TEXT, pub_date TEXT, is_read INTEGER)")
            (sqlite-execute db "CREATE INDEX IF NOT EXISTS idx_is_read ON articles(is_read)")
            (sqlite-execute db "CREATE INDEX IF NOT EXISTS idx_feed_url ON articles(feed_url)")
            ;; Fails when the column is already there.
            (ignore-errors
              (sqlite-execute db "ALTER TABLE articles ADD COLUMN is_starred INTEGER DEFAULT 0"))
            (setq ewv-rss--db db))))))

(defun ewv-rss--close-db ()
  (when ewv-rss--db
    (ignore-errors (sqlite-close ewv-rss--db))
    (setq ewv-rss--db nil)))

(defun ewv-rss--node-condition (node-id)
  "Return (SQL . VALUES) selecting the articles of the node NODE-ID."
  (pcase node-id
    ("unread" (list "is_read = 0"))
    ("starred" (list "is_starred = 1"))
    (_ (let ((urls (ewv-rss--node-feeds (gethash node-id ewv-rss--nodes))))
         (if urls
             (cons (format "feed_url IN (%s)" (mapconcat (lambda (_) "?") urls ","))
                   urls)
           (list "0"))))))

(defun ewv-rss--counts ()
  "Return a table: node id -> its unread (for Starred, starred) count."
  (let ((db (ewv-rss--db))
        (by-feed (make-hash-table :test #'equal))
        (counts (make-hash-table :test #'equal)))
    (pcase-dolist (`(,url ,n) (sqlite-select db "SELECT feed_url, COUNT(*) FROM articles
WHERE is_read = 0 GROUP BY feed_url"))
      (puthash url n by-feed))
    (cl-labels ((walk (node)
                  (let ((n (apply #'+ (gethash (ewv-rss-node-url node) by-feed 0)
                                  (mapcar #'walk (ewv-rss-node-children node)))))
                    (puthash (ewv-rss-node-id node) n counts)
                    n)))
      (mapc #'walk (cddr ewv-rss--tree)))
    (puthash "unread" (caar (sqlite-select db "SELECT COUNT(*) FROM articles WHERE is_read = 0"))
             counts)
    (puthash "starred" (caar (sqlite-select db "SELECT COUNT(*) FROM articles WHERE is_starred = 1"))
             counts)
    counts))

(defun ewv-rss--date (string)
  "Seconds since the epoch for the feed date STRING, or 0 when it has none."
  (if (or (null string) (string-empty-p string))
      0
    (or (gethash string ewv-rss--dates)
        (puthash string
                 (or (ignore-errors (float-time (date-to-time string))) 0)
                 ewv-rss--dates))))

(defun ewv-rss--articles (node-id)
  "The articles of the node NODE-ID for the list, newest first."
  (pcase-let* ((`(,where . ,values) (ewv-rss--node-condition node-id))
               (rows (sqlite-select
                      (ewv-rss--db)
                      (concat "SELECT id, title, substr(CASE WHEN summary IS NULL OR summary = ''
THEN coalesce(content, '') ELSE summary END, 1, 1500), pub_date, is_read, is_starred, feed_url
FROM articles WHERE " where)
                      values)))
    (setq rows (sort (mapcar (lambda (row) (cons (ewv-rss--date (nth 3 row)) row)) rows)
                     (lambda (a b) (> (car a) (car b)))))
    (vconcat
     (mapcar (pcase-lambda (`(,ts ,id ,title ,summary ,_date ,read ,starred ,feed))
               (list :id id :title (or title "") :summary (or summary "")
                     :feed (ewv-rss--feed-name feed) :ts ts
                     :read (ewv-rss--bool (eql read 1))
                     :starred (ewv-rss--bool (eql starred 1))))
             (seq-take rows ewv-rss-list-limit)))))

(defun ewv-rss--article (id)
  "The article ID in full, as a plist for the page, or nil."
  (pcase (car (sqlite-select (ewv-rss--db) "SELECT title, summary, content, link, pub_date,
is_read, is_starred, feed_url FROM articles WHERE id = ?" (list id)))
    (`(,title ,summary ,content ,link ,date ,read ,starred ,feed)
     (list :id id :title (or title "")
           :content (if (or (null content) (string-empty-p content)) (or summary "") content)
           :link (or link "") :date (or date "") :ts (ewv-rss--date date)
           :feed (ewv-rss--feed-name feed)
           :read (ewv-rss--bool (eql read 1))
           :starred (ewv-rss--bool (eql starred 1))))))

(defun ewv-rss--set-flag (column id value)
  "Set COLUMN (is_read or is_starred) of the article ID to VALUE."
  (sqlite-execute (ewv-rss--db)
                  (format "UPDATE articles SET %s = ? WHERE id = ?" column)
                  (list (if value 1 0) id))
  (when ewv-rss-org-mirror
    (ewv-rss--org-sync (list id))))

;;; Org mirror (optional)

(defun ewv-rss--safe-name (name)
  (let ((safe (string-trim (replace-regexp-in-string "[/\\\\:*?\"<>|[:cntrl:]]" "-" name)
                           nil "[. ]+")))
    (if (string-empty-p safe) "feed" safe)))

(defun ewv-rss--org-file (feed-url)
  "The Org file mirroring the feed FEED-URL, or nil if it is not subscribed."
  (when-let* ((node (gethash feed-url ewv-rss--feed-nodes)))
    (let ((parts nil)
          (parent (ewv-rss-node-parent node)))
      (while (and parent (ewv-rss-node-parent parent))
        (push (ewv-rss--safe-name (ewv-rss-node-name parent)) parts)
        (setq parent (ewv-rss-node-parent parent)))
      (expand-file-name
       (concat (ewv-rss--safe-name (ewv-rss-node-name node)) ".org")
       (expand-file-name (string-join parts "/")
                         (expand-file-name "org_rss_data" ewv-rss-data-directory))))))

(defun ewv-rss--org-append (feed-url id title date link body)
  (when-let* ((file (ewv-rss--org-file feed-url)))
    (make-directory (file-name-directory file) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region
       (format "\n* %s\n:PROPERTIES:\n:ID: %s\n:PUB_DATE: %s\n:LINK: %s\n:END:\n\n#+begin_export html\n%s\n#+end_export\n"
               (replace-regexp-in-string "[\n\r]+" " " (or title "Untitled"))
               id (or date "") (or link "")
               ;; Org's own escape for lines that would end the block or
               ;; start a heading.
               (replace-regexp-in-string "^\\(\\*\\|#\\+\\)" ",\\1" (or body "")))
       nil file t 'silent))))

(defun ewv-rss--org-sync (ids)
  "Write the read and starred state of the articles IDS to their Org entries."
  (let ((by-file nil))
    (dolist (id ids)
      (pcase (car (sqlite-select (ewv-rss--db) "SELECT feed_url, is_read, is_starred
FROM articles WHERE id = ?" (list id)))
        (`(,feed ,read ,starred)
         (when-let* ((file (ewv-rss--org-file feed)))
           (push (list id (eql read 1) (eql starred 1))
                 (alist-get file by-file nil nil #'equal))))))
    (pcase-dolist (`(,file . ,rows) by-file)
      (when (file-exists-p file)
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8)
                (coding-system-for-write 'utf-8-unix))
            (insert-file-contents file)
            (pcase-dolist (`(,id ,read ,starred) rows)
              (goto-char (point-min))
              (when (search-forward (format ":ID: %s\n" id) nil t)
                (let ((start (save-excursion (search-backward ":PROPERTIES:" nil t)))
                      (end (save-excursion (and (search-forward ":END:" nil t)
                                                (copy-marker (match-beginning 0))))))
                  (when (and start end)
                    (goto-char start)
                    (while (re-search-forward "^:\\(?:STARRED\\|IS_READ\\):.*\n" end t)
                      (replace-match ""))
                    (goto-char end)
                    (when starred (insert ":STARRED: 1\n"))
                    (when read (insert ":IS_READ: 1\n"))))))
            (write-region nil nil file nil 'silent)))))))

;;; Feed parsing

(defun ewv-rss--clean (string)
  "STRING trimmed and without characters JSON cannot carry; nil if empty."
  (when string
    (let ((s (string-trim
              (replace-regexp-in-string "[^\0-\xd7ff\xe000-\x10ffff]" "\ufffd" string))))
      (unless (string-empty-p s) s))))

(defun ewv-rss--tag (node)
  "The element name of NODE without its namespace prefix."
  (let ((name (symbol-name (car node))))
    (if (string-match ":\\([^:]+\\)\\'" name) (match-string 1 name) name)))

(defun ewv-rss--node-text (node)
  (ewv-rss--clean (dom-texts node "")))

(defun ewv-rss--node-html (node)
  "The content of NODE as HTML: its text, or its child elements serialized."
  (let ((children (cddr node)))
    (ewv-rss--clean
     (if (cl-some (lambda (child) (and (consp child) (not (eq (car child) 'comment))))
                  children)
         ;; Atom's type="xhtml": the markup is the XML itself.
         (with-temp-buffer
           (dolist (child children)
             (cond ((stringp child) (insert (xml-escape-string child)))
                   ((eq (car child) 'comment))
                   (t (dom-print child))))
           (buffer-string))
       (mapconcat (lambda (child) (if (stringp child) child "")) children "")))))

(defun ewv-rss--find-entries (node)
  "The item (RSS) and entry (Atom) elements under NODE."
  (let ((found nil))
    (dolist (child (cddr node))
      (when (consp child)
        (if (member (ewv-rss--tag child) '("item" "entry"))
            (push child found)
          (setq found (nconc (nreverse (ewv-rss--find-entries child)) found)))))
    (nreverse found)))

(defun ewv-rss--entry (item feed-url)
  "Return (ID TITLE SUMMARY CONTENT LINK DATE) for the feed element ITEM."
  (let (title id summary content link other-link date updated)
    (dolist (child (cddr item))
      (when (consp child)
        (pcase (ewv-rss--tag child)
          ("title" (unless title (setq title (ewv-rss--node-text child))))
          ((or "guid" "id") (unless id (setq id (ewv-rss--node-text child))))
          ((or "description" "summary")
           (unless summary (setq summary (ewv-rss--node-html child))))
          ;; content:encoded and Atom's content.  libxml drops the prefix, so
          ;; media:content looks the same; it is the one with a url.
          ((or "encoded" "content")
           (unless (or content (assq 'url (cadr child)) (assq 'medium (cadr child)))
             (setq content (ewv-rss--node-html child))))
          ("link"
           (let ((href (ewv-rss--clean (cdr (assq 'href (cadr child)))))
                 (rel (cdr (assq 'rel (cadr child)))))
             (cond ((and href (member rel '(nil "alternate")))
                    (unless link (setq link href)))
                   (href (unless other-link (setq other-link href)))
                   (t (unless link (setq link (ewv-rss--node-text child)))))))
          ((or "pubDate" "published") (unless date (setq date (ewv-rss--node-text child))))
          ((or "updated" "date" "modified")
           (unless updated (setq updated (ewv-rss--node-text child)))))))
    ;; A guid is the article's URL unless the feed says otherwise.
    (setq link (or link other-link (ewv-rss--http-url id))
          date (or date updated))
    (when (and link (not (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" link)))
      (setq link (ignore-errors (url-expand-file-name link feed-url))))
    (setq id (or id link
                 (and (or title date) (secure-hash 'sha1 (concat title "\n" date)))))
    ;; Ids are only unique within their feed unless they are URIs.
    (when (and id (not (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" id)))
      (setq id (concat feed-url "#" id)))
    (and id (list id title summary content link date))))

(defun ewv-rss--parse (text)
  "Parse the feed document TEXT into one XML node."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    ;; libxml gets the text already decoded: the declared encoding is stale.
    (when (re-search-forward "\\`[^<]*\\(?:<\\?xml[^>]*\\?>\\)?" nil t)
      (delete-region (point-min) (point)))
    (if (and (fboundp 'libxml-available-p) (libxml-available-p))
        (list 'top nil (libxml-parse-xml-region (point-min) (point-max)))
      (cons 'top (cons nil (xml-parse-region (point-min) (point-max)))))))

(defun ewv-rss--ingest (feed-url)
  "Store the feed FEED-URL from the HTTP response in the current buffer.
Return the number of articles that were new."
  (let ((status (bound-and-true-p url-http-response-status)))
    (unless (and (integerp status) (<= 200 status 299))
      (error "HTTP status %s" status)))
  (goto-char (point-min))
  (unless (re-search-forward "\r?\n\r?\n" nil t)
    (error "No response body"))
  (let* ((body (buffer-substring-no-properties (point) (point-max)))
         (declared (and (string-match "\\`[^<]*<\\?xml[^>]*encoding=[\"']\\([^\"']+\\)[\"']" body)
                        (intern (downcase (match-string 1 body)))))
         (text (decode-coding-string body (if (coding-system-p declared) declared 'utf-8)))
         (entries (ewv-rss--find-entries (ewv-rss--parse text)))
         (db (ewv-rss--db))
         (new 0))
    (unless entries
      (unless (string-match-p "<\\(?:rss\\|feed\\|rdf:RDF\\)[ \t\n>]" text)
        (error "Not a feed")))
    (sqlite-transaction db)
    (unwind-protect
        (dolist (item entries)
          (pcase (ewv-rss--entry item feed-url)
            (`(,id ,title ,summary ,content ,link ,date)
             (when (> (sqlite-execute db "INSERT OR IGNORE INTO articles
(id, feed_url, title, summary, content, link, pub_date, is_read) VALUES (?, ?, ?, ?, ?, ?, ?, 0)"
                                      (list id feed-url title summary content link date))
                      0)
               (cl-incf new)
               (when ewv-rss-org-mirror
                 (ewv-rss--org-append feed-url id title date link (or content summary)))))))
      (sqlite-commit db))
    new))

;;; Fetching

(defun ewv-rss--fetching-p ()
  (or ewv-rss--queue (> ewv-rss--active 0)))

(defun ewv-rss--post-fetching ()
  (ewv-rss--post "fetching" :active (ewv-rss--bool (ewv-rss--fetching-p))
                 :done ewv-rss--done :total ewv-rss--total))

(defun ewv-rss--covers-p (node-id feed-url)
  "Non-nil if the list of the node NODE-ID can hold articles of FEED-URL."
  (or (equal node-id "unread")
      (member feed-url (ewv-rss--node-feeds (gethash node-id ewv-rss--nodes)))))

(defun ewv-rss--feed-finished (feed-url new error)
  "Account for the end of the download of FEED-URL: NEW articles, or ERROR."
  (cl-decf ewv-rss--active)
  (cl-incf ewv-rss--done)
  (cl-incf ewv-rss--new new)
  (when error
    (push (cons feed-url error) ewv-rss--failed))
  (when (> new 0)
    (ewv-rss--post "counts" :counts (ewv-rss--counts))
    (when (ewv-rss--covers-p ewv-rss--selected feed-url)
      (ewv-rss--post "articles" :node ewv-rss--selected
                     :items (ewv-rss--articles ewv-rss--selected) :keep t)))
  (ewv-rss--pump)
  (ewv-rss--post-fetching)
  (unless (ewv-rss--fetching-p)
    (message "ewv-rss: %d new article%s%s" ewv-rss--new (if (= ewv-rss--new 1) "" "s")
             (if ewv-rss--failed
                 (format ", %d feed%s failed (M-x ewv-rss-show-failures)"
                         (length ewv-rss--failed) (if (cdr ewv-rss--failed) "s" ""))
               ""))))

(defun ewv-rss--fetch (feed-url)
  "Download and store FEED-URL, then report to `ewv-rss--feed-finished'."
  (let* ((generation ewv-rss--generation)
         (finished nil)
         (timer nil)
         (buffer nil)
         (finish (lambda (new error)
                   (unless finished
                     (setq finished t)
                     (when timer (cancel-timer timer))
                     (when (= generation ewv-rss--generation)
                       (ewv-rss--feed-finished feed-url new error))))))
    (cl-incf ewv-rss--active)
    (condition-case err
        (setq buffer
              (url-retrieve
               feed-url
               (lambda (status)
                 (let ((response (current-buffer))
                       (new 0)
                       (error nil))
                   (condition-case err
                       (if (plist-get status :error)
                           (setq error (format "%S" (plist-get status :error)))
                         (when (= generation ewv-rss--generation)
                           (setq new (ewv-rss--ingest feed-url))))
                     (error (setq error (error-message-string err))))
                   (when (buffer-live-p response)
                     (kill-buffer response))
                   (funcall finish new error)))
               nil t t))
      (error (funcall finish 0 (error-message-string err))))
    (unless finished
      (setq timer
            (run-at-time
             ewv-rss-fetch-timeout nil
             (lambda ()
               (unless finished
                 (funcall finish 0 "timed out")
                 (when (buffer-live-p buffer)
                   (when-let* ((process (get-buffer-process buffer)))
                     (delete-process process))
                   (kill-buffer buffer)))))))))

(defun ewv-rss--pump ()
  (while (and ewv-rss--queue (< ewv-rss--active ewv-rss-fetch-concurrency))
    (ewv-rss--fetch (pop ewv-rss--queue))))

(defun ewv-rss-refresh ()
  "Fetch all subscribed feeds."
  (interactive)
  (cond
   ((not (ewv-rss--webview))
    (when (called-interactively-p 'any)
      (user-error "The reader is not open; run M-x ewv-rss")))
   ((ewv-rss--fetching-p)
    (when (called-interactively-p 'any)
      (message "ewv-rss: already fetching (%d/%d)" ewv-rss--done ewv-rss--total)))
   (t
    (setq ewv-rss--fetched t
          ewv-rss--queue (hash-table-keys ewv-rss--feed-nodes)
          ewv-rss--total (length ewv-rss--queue)
          ewv-rss--done 0
          ewv-rss--new 0
          ewv-rss--failed nil)
    (ewv-rss--pump)
    (ewv-rss--post-fetching))))

(defun ewv-rss-show-failures ()
  "List the feeds the last fetch could not get, with the reason."
  (interactive)
  (if (null ewv-rss--failed)
      (message "ewv-rss: the last fetch had no failures")
    (with-help-window "*ewv-rss failures*"
      (pcase-dolist (`(,url . ,reason) (reverse ewv-rss--failed))
        (princ (format "%s\n    %s\n" url reason))))))

;;; Requests from the page

(defun ewv-rss--from-page-p (source)
  "Non-nil if SOURCE, the URI of a message's sender, is the reader page."
  (string= (downcase (url-unhex-string (car (split-string source "[?#]"))))
           (downcase (ewv-rss--page-url))))

(defun ewv-rss--post-init ()
  (ewv-rss--post "init" :tree (ewv-rss--tree-json ewv-rss--tree)
                 :counts (ewv-rss--counts) :selected ewv-rss--selected
                 :fetching (list :active (ewv-rss--bool (ewv-rss--fetching-p))
                                 :done ewv-rss--done :total ewv-rss--total)))

(defun ewv-rss--post-state (id)
  (pcase (car (sqlite-select (ewv-rss--db) "SELECT is_read, is_starred FROM articles
WHERE id = ?" (list id)))
    (`(,read ,starred)
     (ewv-rss--post "state" :id id :read (ewv-rss--bool (eql read 1))
                    :starred (ewv-rss--bool (eql starred 1)))))
  (ewv-rss--post "counts" :counts (ewv-rss--counts)))

(defun ewv-rss--http-url (url)
  "URL if it is a string holding an http(s) URL, else nil."
  (and (stringp url) (string-match-p "\\`https?://" url) url))

(defun ewv-rss--handle (msg)
  "Carry out MSG, a request of the page parsed into an alist."
  (let-alist msg
    (pcase .op
      ("ready"
       (ewv-rss--post-init)
       (unless ewv-rss--fetched (ewv-rss-refresh)))
      ("select"
       (when (stringp .node)
         (setq ewv-rss--selected .node)
         (ewv-rss--post "articles" :node .node :items (ewv-rss--articles .node))))
      ("open"
       (when-let* (((stringp .id))
                   (article (ewv-rss--article .id)))
         (when (eq (plist-get article :read) :false)
           (ewv-rss--set-flag "is_read" .id t)
           (plist-put article :read t))
         (ewv-rss--post "article" :article article)
         (ewv-rss--post "counts" :counts (ewv-rss--counts))))
      ("star"
       (when (stringp .id)
         (ewv-rss--set-flag "is_starred" .id .value)
         (ewv-rss--post-state .id)))
      ("read"
       (when (stringp .id)
         (ewv-rss--set-flag "is_read" .id .value)
         (ewv-rss--post-state .id)))
      ("mark-all-read"
       (when (stringp .node)
         (pcase-let* ((`(,where . ,values) (ewv-rss--node-condition .node))
                      (where (concat "is_read = 0 AND (" where ")"))
                      (ids (and ewv-rss-org-mirror
                                (mapcar #'car (sqlite-select
                                               (ewv-rss--db)
                                               (concat "SELECT id FROM articles WHERE " where)
                                               values)))))
           (sqlite-execute (ewv-rss--db)
                           (concat "UPDATE articles SET is_read = 1 WHERE " where) values)
           (when ids (ewv-rss--org-sync ids)))
         (ewv-rss--post "articles" :node .node :items (ewv-rss--articles .node) :keep t)
         (ewv-rss--post "counts" :counts (ewv-rss--counts))))
      ("refresh" (ewv-rss-refresh))
      ;; Creating a webview pumps window messages; do it outside this handler.
      ("open-link"
       (when-let* ((url (ewv-rss--http-url .url)))
         (run-at-time 0 nil #'ewv-browser-open-url url)))
      ("open-external"
       (when-let* ((url (ewv-rss--http-url .url)))
         (browse-url-default-browser url)))
      ("focus-emacs" (ewv-native-focus-frame (selected-frame))))))

(defun ewv-rss--on-message (source json)
  "Handle the web message JSON sent by the document at SOURCE."
  (condition-case err
      (if (ewv-rss--from-page-p source)
          (ewv-rss--handle (json-parse-string json :object-type 'alist
                                              :null-object nil :false-object nil))
        (message "ewv-rss: ignored a message from %s" source))
    (error (message "ewv-rss: %s" (error-message-string err)))))

;;; The buffer

(defun ewv-rss--cleanup ()
  "Stop everything the reader started; its buffer is going away."
  (cl-incf ewv-rss--generation)
  (when ewv-rss--timer
    (cancel-timer ewv-rss--timer)
    (setq ewv-rss--timer nil))
  (setq ewv-rss--queue nil
        ewv-rss--active 0
        ewv-rss--fetched nil)
  (ewv-rss--close-db))

(defmacro ewv-rss--define-commands (&rest specs)
  "Define a command for each (NAME PAGE-COMMAND DOC) in SPECS."
  (macroexp-progn
   (mapcar (pcase-lambda (`(,name ,command ,doc))
             `(defun ,name ()
                ,doc
                (interactive)
                (ewv-rss--post "cmd" :name ,command)))
           specs)))

(ewv-rss--define-commands
 (ewv-rss-next-article "next" "Show the next article of the list.")
 (ewv-rss-previous-article "prev" "Show the previous article of the list.")
 (ewv-rss-toggle-star "star" "Star or unstar the article shown.")
 (ewv-rss-toggle-read "toggle-read" "Mark the article shown unread, or read again.")
 (ewv-rss-open-original "open-original" "Open the article's own page in a new ewv buffer.")
 (ewv-rss-open-external "open-external" "Open the article's own page in the default browser.")
 (ewv-rss-mark-all-read "mark-all-read" "Mark every article of the list as read.")
 (ewv-rss-scroll-up "page-down" "Scroll the article forward.")
 (ewv-rss-scroll-down "page-up" "Scroll the article back."))

(defun ewv-rss-edit-feeds ()
  "Visit the subscriptions (`ewv-rss-path'); `ewv-rss-reload-feeds' applies edits."
  (interactive)
  (find-file-other-window ewv-rss-path))

(defun ewv-rss-reload-feeds ()
  "Read the subscriptions again and fetch them."
  (interactive)
  (unless (ewv-rss--webview)
    (user-error "The reader is not open; run M-x ewv-rss"))
  (ewv-rss--load-tree)
  (ewv-rss--post-init)
  (ewv-rss-refresh))

(defvar ewv-rss-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'ewv-rss-next-article)
    (define-key map "j" #'ewv-rss-next-article)
    (define-key map "p" #'ewv-rss-previous-article)
    (define-key map "k" #'ewv-rss-previous-article)
    (define-key map "s" #'ewv-rss-toggle-star)
    (define-key map "u" #'ewv-rss-toggle-read)
    (define-key map "o" #'ewv-rss-open-original)
    (define-key map (kbd "RET") #'ewv-rss-open-original)
    (define-key map "b" #'ewv-rss-open-external)
    (define-key map "A" #'ewv-rss-mark-all-read)
    (define-key map (kbd "SPC") #'ewv-rss-scroll-up)
    (define-key map (kbd "DEL") #'ewv-rss-scroll-down)
    (define-key map (kbd "S-SPC") #'ewv-rss-scroll-down)
    (define-key map "r" #'ewv-rss-refresh)
    (define-key map "g" #'ewv-rss-refresh)
    (define-key map "G" #'ewv-rss-reload-feeds)
    (define-key map "e" #'ewv-rss-edit-feeds)
    ;; These would navigate the reader's webview away from the reader.
    (define-key map "f" #'undefined)
    ;; Remaps do not chain, so these replace the parent map's own remaps.
    (define-key map [remap revert-buffer] #'ewv-rss-refresh)
    (define-key map [remap scroll-up-command] #'ewv-rss-scroll-up)
    (define-key map [remap scroll-down-command] #'ewv-rss-scroll-down)
    (define-key map [remap next-line] #'ewv-rss-next-article)
    (define-key map [remap previous-line] #'ewv-rss-previous-article)
    map))

(define-derived-mode ewv-rss-mode ewv-browser-mode "EWV-RSS"
  "Major mode of the buffer whose window the ewv RSS reader covers.
The reader is a web page; these keys drive it while the focus is in Emacs.
\\<ewv-rss-mode-map>\\[ewv-browser-focus-webpage] moves the focus into the page, where the same keys work.

\\{ewv-rss-mode-map}"
  (add-hook 'kill-buffer-hook #'ewv-rss--cleanup nil t)
  (add-hook 'change-major-mode-hook #'ewv-rss--cleanup nil t))

(defun ewv-rss--ensure-path ()
  "Make sure `ewv-rss-path' names an existing file or directory."
  (unless ewv-rss-path
    (let ((path (expand-file-name
                 (read-file-name "elfeed.org file, or a directory of such files: "))))
      ;; Saving fails under emacs -Q; the session still uses the answer.
      (condition-case nil
          (customize-save-variable 'ewv-rss-path path)
        (error (setq ewv-rss-path path)))))
  (unless (file-exists-p ewv-rss-path)
    (user-error "`ewv-rss-path' does not exist: %s" ewv-rss-path)))

;;;###autoload
(defun ewv-rss ()
  "Open the RSS reader, or go back to it.
The subscriptions are read from `ewv-rss-path', an elfeed-org file or a
directory of such files."
  (interactive)
  (let ((buffer (get-buffer ewv-rss--buffer-name)))
    (if (and buffer (buffer-local-value 'ewv-browser--local-id buffer))
        (switch-to-buffer buffer)
      (ewv-rss--ensure-path)
      (ewv-rss--db)
      (ewv-rss--load-tree)
      (ewv-browser--check-user-data-dir)
      (let* ((frame (selected-frame))
             (id (ewv-browser--webview-new frame))
             (buffer (get-buffer-create ewv-rss--buffer-name)))
        (ewv-native-webview-set-on-web-message id #'ewv-rss--on-message)
        (ewv-native-webview-set-on-new-window-requested
         id #'ewv-browser--on-new-window-requested)
        (ewv-native-webview-set-on-focus
         id (lambda (focused) (ewv-browser--on-focus-change focused buffer)))
        (with-current-buffer buffer
          (ewv-rss-mode)
          (setq-local ewv-browser--local-id id
                      ewv-browser--local-frame frame
                      ewv-browser--local-special t))
        (when ewv-rss-refresh-interval
          (setq ewv-rss--timer
                (run-with-timer ewv-rss-refresh-interval ewv-rss-refresh-interval
                                #'ewv-rss-refresh)))
        (ewv-native-webview-load id (ewv-rss--page-url)
                                 (lambda (_title _url) (switch-to-buffer buffer)))))))

(provide 'ewv-rss)

;;; ewv-rss.el ends here

;;; winine-rss.el --- RSS reader in a WebView2 view  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Windows counterpart of appine's RSS reader (`appine-rss'):
;;
;;   (setq winine-rss-path "~/.emacs.d/elfeed/elfeed.org")
;;   M-x winine-rss
;;
;; The subscriptions come from an elfeed-org file (or a directory of them):
;; headings are folders, a heading that is a link or a URL is a feed.  The
;; reader is one buffer covered by a webview showing rss.html: a sidebar with
;; the feed tree and unread counts, the article list, and the article itself.
;;
;; Emacs does the work; the page only displays.  Emacs fetches the feeds
;; (url.el), parses them (libxml), and keeps the articles with their read and
;; starred state in SQLite.  The two talk in web messages: the page posts
;; requests (`winine-rss--on-message'), Emacs posts data back (`winine-rss--post').
;; Feed content is untrusted HTML, so the page shows it only in a sandboxed
;; frame, and of what the page asks, Emacs opens nothing but http(s) links.
;;
;; The database has the schema of appine's (<data dir>/db/rss.sqlite), so
;; `winine-rss-data-directory' can point at a copy of an "appine-rss" directory.
;;
;; Keys, in the page and (with the focus in Emacs) in the buffer:
;;   j/n k/p   next / previous article      s   star
;;   u         read / unread                o   open the original in winine
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
(require 'winine-browser)

(defgroup winine-rss nil
  "RSS reader based on winine."
  :group 'winine
  :prefix "winine-rss-")

(defcustom winine-rss-path nil
  "The subscriptions: an elfeed-org file, or a directory of such files.
When nil, `winine-rss' asks for it on its first run and saves the answer."
  :type '(choice (const :tag "Not set" nil) (file :tag "File or directory")))

(defcustom winine-rss-data-directory
  (expand-file-name "winine-rss" (or (getenv "LOCALAPPDATA") user-emacs-directory))
  "Where the articles are kept (db/rss.sqlite, and org_rss_data/ if mirrored).
The layout and the database schema are those of appine's \"appine-rss\"
directory."
  :type 'directory)

(defcustom winine-rss-refresh-interval 900
  "Seconds between automatic fetches while the reader is open, or nil for none."
  :type '(choice (const :tag "Never" nil) natnum))

(defcustom winine-rss-fetch-concurrency 6
  "How many feeds to download at the same time."
  :type 'natnum)

(defcustom winine-rss-fetch-timeout 30
  "Seconds after which a feed that has not answered is given up."
  :type 'natnum)

(defcustom winine-rss-list-limit 2000
  "The most articles shown for one feed or folder (the newest ones)."
  :type 'natnum)

(defcustom winine-rss-org-mirror nil
  "Non-nil to also write every article to an Org file, as appine does.
The files are <data dir>/org_rss_data/<folder>/<feed>.org, one entry per
article, with its read and starred state in the property drawer."
  :type 'boolean)

(defconst winine-rss--buffer-name "*winine-rss*")

(cl-defstruct (winine-rss-node (:constructor winine-rss-node--make))
  id name url kind children parent)

(defvar winine-rss--db nil "The open SQLite database, or nil.")
(defvar winine-rss--tree nil "The top-level nodes shown in the sidebar.")
(defvar winine-rss--nodes (make-hash-table :test #'equal) "Node id -> node.")
(defvar winine-rss--feed-nodes (make-hash-table :test #'equal) "Feed URL -> its first node.")
(defvar winine-rss--selected "unread" "Id of the node whose articles the page lists.")
(defvar winine-rss--fetched nil "Non-nil once this reader has fetched the feeds.")

(defvar winine-rss--queue nil "Feed URLs waiting to be downloaded.")
(defvar winine-rss--active 0 "Number of downloads in flight.")
(defvar winine-rss--total 0 "Number of feeds in the current fetch.")
(defvar winine-rss--done 0 "Number of feeds finished in the current fetch.")
(defvar winine-rss--new 0 "Number of new articles found by the current fetch.")
(defvar winine-rss--failed nil "Feeds the current fetch could not get: (URL . REASON).")
(defvar winine-rss--generation 0 "Bumped to make downloads of a closed reader void.")
(defvar winine-rss--timer nil "The automatic refresh timer.")
(defvar winine-rss--dates (make-hash-table :test #'equal) "Date string -> seconds.")

;;; The page

(defun winine-rss--page-url ()
  (concat "file:///" (expand-file-name "rss.html" winine-core--src-dir)))

(defun winine-rss--webview ()
  "The id of the reader's webview, or nil when the reader is not open."
  (when-let* ((buffer (get-buffer winine-rss--buffer-name)))
    (buffer-local-value 'winine-browser--local-id buffer)))

(defun winine-rss--post (type &rest props)
  "Send the page a message of TYPE with PROPS, a plist of JSON values."
  (when-let* ((id (winine-rss--webview)))
    (winine-native-webview-post-web-message
     id (winine-core--json (cons :type (cons type props))))))

(defun winine-rss--bool (value)
  (if value t :false))

;;; Subscriptions (elfeed-org)

(defun winine-rss--parse-heading (text)
  "Return (NAME . URL) for the heading TEXT; URL is nil for a folder."
  (cond
   ((string-match "\\`\\[\\[\\([^]]+\\)\\]\\(?:\\[\\([^]]*\\)\\]\\)?\\]" text)
    (let ((url (match-string 1 text))
          (name (match-string 2 text)))
      (cons (if (or (null name) (string-empty-p name)) (winine-rss--host url) name) url)))
   ((string-match "\\`https?://[^ \t]+" text)
    (let ((url (match-string 0 text)))
      (cons (winine-rss--host url) url)))
   (t (cons text nil))))

(defun winine-rss--host (url)
  (or (ignore-errors (url-host (url-generic-parse-url url))) url))

(defun winine-rss--load-tree ()
  "Read `winine-rss-path' into `winine-rss--tree'."
  (let ((root (winine-rss-node--make :id "root" :name "Subscriptions" :kind "group"))
        (files (if (file-directory-p winine-rss-path)
                   (directory-files winine-rss-path t "\\.org\\'")
                 (list winine-rss-path)))
        (count 0))
    (clrhash winine-rss--nodes)
    (clrhash winine-rss--feed-nodes)
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
                (pcase-let* ((`(,name . ,url) (winine-rss--parse-heading text))
                             (node (winine-rss-node--make
                                    :id (format "n%d" (cl-incf count))
                                    :name name :url url
                                    :kind (if url "feed" "group"))))
                  (while (> (length stack) depth) (pop stack))
                  (let ((parent (car stack)))
                    (setf (winine-rss-node-parent node) parent)
                    (setf (winine-rss-node-children parent)
                          (nconc (winine-rss-node-children parent) (list node))))
                  (push node stack)
                  (puthash (winine-rss-node-id node) node winine-rss--nodes)
                  (when (and url (not (gethash url winine-rss--feed-nodes)))
                    (puthash url node winine-rss--feed-nodes)))))))))
    (setq winine-rss--tree
          (append (list (winine-rss-node--make :id "unread" :name "Unread" :kind "unread")
                        (winine-rss-node--make :id "starred" :name "Starred" :kind "starred"))
                  (winine-rss-node-children root)))))

(defun winine-rss--node-feeds (node)
  "The feed URLs of NODE and everything under it."
  (when node
    (delete-dups
     (append (and (winine-rss-node-url node) (list (winine-rss-node-url node)))
             (mapcan #'winine-rss--node-feeds (winine-rss-node-children node))))))

(defun winine-rss--feed-name (url)
  (if-let* ((node (gethash url winine-rss--feed-nodes)))
      (winine-rss-node-name node)
    ""))

(defun winine-rss--tree-json (nodes)
  (vconcat
   (mapcar (lambda (node)
             (list :id (winine-rss-node-id node)
                   :name (winine-rss-node-name node)
                   :kind (winine-rss-node-kind node)
                   :children (winine-rss--tree-json (winine-rss-node-children node))))
           nodes)))

;;; Database

(defun winine-rss--db ()
  "The article database, opened (and created) on first use."
  (or winine-rss--db
      (progn
        (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
          (user-error "winine-rss needs an Emacs built with SQLite support"))
        (let ((dir (expand-file-name "db" winine-rss-data-directory)))
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
            (setq winine-rss--db db))))))

(defun winine-rss--close-db ()
  (when winine-rss--db
    (ignore-errors (sqlite-close winine-rss--db))
    (setq winine-rss--db nil)))

(defun winine-rss--node-condition (node-id)
  "Return (SQL . VALUES) selecting the articles of the node NODE-ID."
  (pcase node-id
    ("unread" (list "is_read = 0"))
    ("starred" (list "is_starred = 1"))
    (_ (let ((urls (winine-rss--node-feeds (gethash node-id winine-rss--nodes))))
         (if urls
             (cons (format "feed_url IN (%s)" (mapconcat (lambda (_) "?") urls ","))
                   urls)
           (list "0"))))))

(defun winine-rss--counts ()
  "Return a table: node id -> its unread (for Starred, starred) count."
  (let ((db (winine-rss--db))
        (by-feed (make-hash-table :test #'equal))
        (counts (make-hash-table :test #'equal)))
    (pcase-dolist (`(,url ,n) (sqlite-select db "SELECT feed_url, COUNT(*) FROM articles
WHERE is_read = 0 GROUP BY feed_url"))
      (puthash url n by-feed))
    (cl-labels ((walk (node)
                  (let ((n (apply #'+ (gethash (winine-rss-node-url node) by-feed 0)
                                  (mapcar #'walk (winine-rss-node-children node)))))
                    (puthash (winine-rss-node-id node) n counts)
                    n)))
      (mapc #'walk (cddr winine-rss--tree)))
    (puthash "unread" (caar (sqlite-select db "SELECT COUNT(*) FROM articles WHERE is_read = 0"))
             counts)
    (puthash "starred" (caar (sqlite-select db "SELECT COUNT(*) FROM articles WHERE is_starred = 1"))
             counts)
    counts))

(defun winine-rss--date (string)
  "Seconds since the epoch for the feed date STRING, or 0 when it has none."
  (if (or (null string) (string-empty-p string))
      0
    (or (gethash string winine-rss--dates)
        (puthash string
                 (or (ignore-errors (float-time (date-to-time string))) 0)
                 winine-rss--dates))))

(defun winine-rss--articles (node-id)
  "The articles of the node NODE-ID for the list, newest first."
  (pcase-let* ((`(,where . ,values) (winine-rss--node-condition node-id))
               (rows (sqlite-select
                      (winine-rss--db)
                      (concat "SELECT id, title, substr(CASE WHEN summary IS NULL OR summary = ''
THEN coalesce(content, '') ELSE summary END, 1, 1500), pub_date, is_read, is_starred, feed_url
FROM articles WHERE " where)
                      values)))
    (setq rows (sort (mapcar (lambda (row) (cons (winine-rss--date (nth 3 row)) row)) rows)
                     (lambda (a b) (> (car a) (car b)))))
    (vconcat
     (mapcar (pcase-lambda (`(,ts ,id ,title ,summary ,_date ,read ,starred ,feed))
               (list :id id :title (or title "") :summary (or summary "")
                     :feed (winine-rss--feed-name feed) :ts ts
                     :read (winine-rss--bool (eql read 1))
                     :starred (winine-rss--bool (eql starred 1))))
             (seq-take rows winine-rss-list-limit)))))

(defun winine-rss--article (id)
  "The article ID in full, as a plist for the page, or nil."
  (pcase (car (sqlite-select (winine-rss--db) "SELECT title, summary, content, link, pub_date,
is_read, is_starred, feed_url FROM articles WHERE id = ?" (list id)))
    (`(,title ,summary ,content ,link ,date ,read ,starred ,feed)
     (list :id id :title (or title "")
           :content (if (or (null content) (string-empty-p content)) (or summary "") content)
           :link (or link "") :date (or date "") :ts (winine-rss--date date)
           :feed (winine-rss--feed-name feed)
           :read (winine-rss--bool (eql read 1))
           :starred (winine-rss--bool (eql starred 1))))))

(defun winine-rss--set-flag (column id value)
  "Set COLUMN (is_read or is_starred) of the article ID to VALUE."
  (sqlite-execute (winine-rss--db)
                  (format "UPDATE articles SET %s = ? WHERE id = ?" column)
                  (list (if value 1 0) id))
  (when winine-rss-org-mirror
    (winine-rss--org-sync (list id))))

;;; Org mirror (optional)

(defun winine-rss--safe-name (name)
  (let ((safe (string-trim (replace-regexp-in-string "[/\\\\:*?\"<>|[:cntrl:]]" "-" name)
                           nil "[. ]+")))
    (if (string-empty-p safe) "feed" safe)))

(defun winine-rss--org-file (feed-url)
  "The Org file mirroring the feed FEED-URL, or nil if it is not subscribed."
  (when-let* ((node (gethash feed-url winine-rss--feed-nodes)))
    (let ((parts nil)
          (parent (winine-rss-node-parent node)))
      (while (and parent (winine-rss-node-parent parent))
        (push (winine-rss--safe-name (winine-rss-node-name parent)) parts)
        (setq parent (winine-rss-node-parent parent)))
      (expand-file-name
       (concat (winine-rss--safe-name (winine-rss-node-name node)) ".org")
       (expand-file-name (string-join parts "/")
                         (expand-file-name "org_rss_data" winine-rss-data-directory))))))

(defun winine-rss--org-append (feed-url id title date link body)
  (when-let* ((file (winine-rss--org-file feed-url)))
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

(defun winine-rss--org-sync (ids)
  "Write the read and starred state of the articles IDS to their Org entries."
  (let ((by-file nil))
    (dolist (id ids)
      (pcase (car (sqlite-select (winine-rss--db) "SELECT feed_url, is_read, is_starred
FROM articles WHERE id = ?" (list id)))
        (`(,feed ,read ,starred)
         (when-let* ((file (winine-rss--org-file feed)))
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

(defun winine-rss--clean (string)
  "STRING trimmed and without characters JSON cannot carry; nil if empty."
  (when string
    (let ((s (string-trim
              (replace-regexp-in-string "[^\0-\xd7ff\xe000-\x10ffff]" "\ufffd" string))))
      (unless (string-empty-p s) s))))

(defun winine-rss--tag (node)
  "The element name of NODE without its namespace prefix."
  (let ((name (symbol-name (car node))))
    (if (string-match ":\\([^:]+\\)\\'" name) (match-string 1 name) name)))

(defun winine-rss--node-text (node)
  (winine-rss--clean (dom-texts node "")))

(defun winine-rss--node-html (node)
  "The content of NODE as HTML: its text, or its child elements serialized."
  (let ((children (cddr node)))
    (winine-rss--clean
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

(defun winine-rss--find-entries (node)
  "The item (RSS) and entry (Atom) elements under NODE."
  (let ((found nil))
    (dolist (child (cddr node))
      (when (consp child)
        (if (member (winine-rss--tag child) '("item" "entry"))
            (push child found)
          (setq found (nconc (nreverse (winine-rss--find-entries child)) found)))))
    (nreverse found)))

(defun winine-rss--entry (item feed-url)
  "Return (ID TITLE SUMMARY CONTENT LINK DATE) for the feed element ITEM."
  (let (title id summary content link other-link date updated)
    (dolist (child (cddr item))
      (when (consp child)
        (pcase (winine-rss--tag child)
          ("title" (unless title (setq title (winine-rss--node-text child))))
          ((or "guid" "id") (unless id (setq id (winine-rss--node-text child))))
          ((or "description" "summary")
           (unless summary (setq summary (winine-rss--node-html child))))
          ;; content:encoded and Atom's content.  libxml drops the prefix, so
          ;; media:content looks the same; it is the one with a url.
          ((or "encoded" "content")
           (unless (or content (assq 'url (cadr child)) (assq 'medium (cadr child)))
             (setq content (winine-rss--node-html child))))
          ("link"
           (let ((href (winine-rss--clean (cdr (assq 'href (cadr child)))))
                 (rel (cdr (assq 'rel (cadr child)))))
             (cond ((and href (member rel '(nil "alternate")))
                    (unless link (setq link href)))
                   (href (unless other-link (setq other-link href)))
                   (t (unless link (setq link (winine-rss--node-text child)))))))
          ((or "pubDate" "published") (unless date (setq date (winine-rss--node-text child))))
          ((or "updated" "date" "modified")
           (unless updated (setq updated (winine-rss--node-text child)))))))
    ;; A guid is the article's URL unless the feed says otherwise.
    (setq link (or link other-link (winine-rss--http-url id))
          date (or date updated))
    (when (and link (not (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" link)))
      (setq link (ignore-errors (url-expand-file-name link feed-url))))
    (setq id (or id link
                 (and (or title date) (secure-hash 'sha1 (concat title "\n" date)))))
    ;; Ids are only unique within their feed unless they are URIs.
    (when (and id (not (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" id)))
      (setq id (concat feed-url "#" id)))
    (and id (list id title summary content link date))))

(defun winine-rss--parse (text)
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

(defun winine-rss--ingest (feed-url)
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
         (entries (winine-rss--find-entries (winine-rss--parse text)))
         (db (winine-rss--db))
         (new 0))
    (unless entries
      (unless (string-match-p "<\\(?:rss\\|feed\\|rdf:RDF\\)[ \t\n>]" text)
        (error "Not a feed")))
    (sqlite-transaction db)
    (unwind-protect
        (dolist (item entries)
          (pcase (winine-rss--entry item feed-url)
            (`(,id ,title ,summary ,content ,link ,date)
             (when (> (sqlite-execute db "INSERT OR IGNORE INTO articles
(id, feed_url, title, summary, content, link, pub_date, is_read) VALUES (?, ?, ?, ?, ?, ?, ?, 0)"
                                      (list id feed-url title summary content link date))
                      0)
               (cl-incf new)
               (when winine-rss-org-mirror
                 (winine-rss--org-append feed-url id title date link (or content summary)))))))
      (sqlite-commit db))
    new))

;;; Fetching

(defun winine-rss--fetching-p ()
  (or winine-rss--queue (> winine-rss--active 0)))

(defun winine-rss--post-fetching ()
  (winine-rss--post "fetching" :active (winine-rss--bool (winine-rss--fetching-p))
                 :done winine-rss--done :total winine-rss--total))

(defun winine-rss--covers-p (node-id feed-url)
  "Non-nil if the list of the node NODE-ID can hold articles of FEED-URL."
  (or (equal node-id "unread")
      (member feed-url (winine-rss--node-feeds (gethash node-id winine-rss--nodes)))))

(defun winine-rss--feed-finished (feed-url new error)
  "Account for the end of the download of FEED-URL: NEW articles, or ERROR."
  (cl-decf winine-rss--active)
  (cl-incf winine-rss--done)
  (cl-incf winine-rss--new new)
  (when error
    (push (cons feed-url error) winine-rss--failed))
  (when (> new 0)
    (winine-rss--post "counts" :counts (winine-rss--counts))
    (when (winine-rss--covers-p winine-rss--selected feed-url)
      (winine-rss--post "articles" :node winine-rss--selected
                     :items (winine-rss--articles winine-rss--selected) :keep t)))
  (winine-rss--pump)
  (winine-rss--post-fetching)
  (unless (winine-rss--fetching-p)
    (message "winine-rss: %d new article%s%s" winine-rss--new (if (= winine-rss--new 1) "" "s")
             (if winine-rss--failed
                 (format ", %d feed%s failed (M-x winine-rss-show-failures)"
                         (length winine-rss--failed) (if (cdr winine-rss--failed) "s" ""))
               ""))))

(defun winine-rss--fetch (feed-url)
  "Download and store FEED-URL, then report to `winine-rss--feed-finished'."
  (let* ((generation winine-rss--generation)
         (finished nil)
         (timer nil)
         (buffer nil)
         (finish (lambda (new error)
                   (unless finished
                     (setq finished t)
                     (when timer (cancel-timer timer))
                     (when (= generation winine-rss--generation)
                       (winine-rss--feed-finished feed-url new error))))))
    (cl-incf winine-rss--active)
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
                         (when (= generation winine-rss--generation)
                           (setq new (winine-rss--ingest feed-url))))
                     (error (setq error (error-message-string err))))
                   (when (buffer-live-p response)
                     (kill-buffer response))
                   (funcall finish new error)))
               nil t t))
      (error (funcall finish 0 (error-message-string err))))
    (unless finished
      (setq timer
            (run-at-time
             winine-rss-fetch-timeout nil
             (lambda ()
               (unless finished
                 (funcall finish 0 "timed out")
                 (when (buffer-live-p buffer)
                   (when-let* ((process (get-buffer-process buffer)))
                     (delete-process process))
                   (kill-buffer buffer)))))))))

(defun winine-rss--pump ()
  (while (and winine-rss--queue (< winine-rss--active winine-rss-fetch-concurrency))
    (winine-rss--fetch (pop winine-rss--queue))))

(defun winine-rss-refresh ()
  "Fetch all subscribed feeds."
  (interactive)
  (cond
   ((not (winine-rss--webview))
    (when (called-interactively-p 'any)
      (user-error "The reader is not open; run M-x winine-rss")))
   ((winine-rss--fetching-p)
    (when (called-interactively-p 'any)
      (message "winine-rss: already fetching (%d/%d)" winine-rss--done winine-rss--total)))
   (t
    (setq winine-rss--fetched t
          winine-rss--queue (hash-table-keys winine-rss--feed-nodes)
          winine-rss--total (length winine-rss--queue)
          winine-rss--done 0
          winine-rss--new 0
          winine-rss--failed nil)
    (winine-rss--pump)
    (winine-rss--post-fetching))))

(defun winine-rss-show-failures ()
  "List the feeds the last fetch could not get, with the reason."
  (interactive)
  (if (null winine-rss--failed)
      (message "winine-rss: the last fetch had no failures")
    (with-help-window "*winine-rss failures*"
      (pcase-dolist (`(,url . ,reason) (reverse winine-rss--failed))
        (princ (format "%s\n    %s\n" url reason))))))

;;; Requests from the page

(defun winine-rss--from-page-p (source)
  "Non-nil if SOURCE, the URI of a message's sender, is the reader page."
  (string= (downcase (url-unhex-string (car (split-string source "[?#]"))))
           (downcase (winine-rss--page-url))))

(defun winine-rss--post-init ()
  (winine-rss--post "init" :tree (winine-rss--tree-json winine-rss--tree)
                 :counts (winine-rss--counts) :selected winine-rss--selected
                 :fetching (list :active (winine-rss--bool (winine-rss--fetching-p))
                                 :done winine-rss--done :total winine-rss--total)))

(defun winine-rss--post-state (id)
  (pcase (car (sqlite-select (winine-rss--db) "SELECT is_read, is_starred FROM articles
WHERE id = ?" (list id)))
    (`(,read ,starred)
     (winine-rss--post "state" :id id :read (winine-rss--bool (eql read 1))
                    :starred (winine-rss--bool (eql starred 1)))))
  (winine-rss--post "counts" :counts (winine-rss--counts)))

(defun winine-rss--http-url (url)
  "URL if it is a string holding an http(s) URL, else nil."
  (and (stringp url) (string-match-p "\\`https?://" url) url))

(defun winine-rss--handle (msg)
  "Carry out MSG, a request of the page parsed into an alist."
  (let-alist msg
    (pcase .op
      ("ready"
       (winine-rss--post-init)
       (unless winine-rss--fetched (winine-rss-refresh)))
      ("select"
       (when (stringp .node)
         (setq winine-rss--selected .node)
         (winine-rss--post "articles" :node .node :items (winine-rss--articles .node))))
      ("open"
       (when-let* (((stringp .id))
                   (article (winine-rss--article .id)))
         (when (eq (plist-get article :read) :false)
           (winine-rss--set-flag "is_read" .id t)
           (plist-put article :read t))
         (winine-rss--post "article" :article article)
         (winine-rss--post "counts" :counts (winine-rss--counts))))
      ("star"
       (when (stringp .id)
         (winine-rss--set-flag "is_starred" .id .value)
         (winine-rss--post-state .id)))
      ("read"
       (when (stringp .id)
         (winine-rss--set-flag "is_read" .id .value)
         (winine-rss--post-state .id)))
      ("mark-all-read"
       (when (stringp .node)
         (pcase-let* ((`(,where . ,values) (winine-rss--node-condition .node))
                      (where (concat "is_read = 0 AND (" where ")"))
                      (ids (and winine-rss-org-mirror
                                (mapcar #'car (sqlite-select
                                               (winine-rss--db)
                                               (concat "SELECT id FROM articles WHERE " where)
                                               values)))))
           (sqlite-execute (winine-rss--db)
                           (concat "UPDATE articles SET is_read = 1 WHERE " where) values)
           (when ids (winine-rss--org-sync ids)))
         (winine-rss--post "articles" :node .node :items (winine-rss--articles .node) :keep t)
         (winine-rss--post "counts" :counts (winine-rss--counts))))
      ("refresh" (winine-rss-refresh))
      ;; Creating a webview pumps window messages; do it outside this handler.
      ("open-link"
       (when-let* ((url (winine-rss--http-url .url)))
         (run-at-time 0 nil #'winine-browser-open-url url)))
      ("open-external"
       (when-let* ((url (winine-rss--http-url .url)))
         (browse-url-default-browser url)))
      ("focus-emacs" (winine-native-focus-frame (selected-frame))))))

(defun winine-rss--on-message (source json)
  "Handle the web message JSON sent by the document at SOURCE."
  (condition-case err
      (if (winine-rss--from-page-p source)
          (winine-rss--handle (json-parse-string json :object-type 'alist
                                              :null-object nil :false-object nil))
        (message "winine-rss: ignored a message from %s" source))
    (error (message "winine-rss: %s" (error-message-string err)))))

;;; The buffer

(defun winine-rss--cleanup ()
  "Stop everything the reader started; its buffer is going away."
  (cl-incf winine-rss--generation)
  (when winine-rss--timer
    (cancel-timer winine-rss--timer)
    (setq winine-rss--timer nil))
  (setq winine-rss--queue nil
        winine-rss--active 0
        winine-rss--fetched nil)
  (winine-rss--close-db))

(defmacro winine-rss--define-commands (&rest specs)
  "Define a command for each (NAME PAGE-COMMAND DOC) in SPECS."
  (macroexp-progn
   (mapcar (pcase-lambda (`(,name ,command ,doc))
             `(defun ,name ()
                ,doc
                (interactive)
                (winine-rss--post "cmd" :name ,command)))
           specs)))

(winine-rss--define-commands
 (winine-rss-next-article "next" "Show the next article of the list.")
 (winine-rss-previous-article "prev" "Show the previous article of the list.")
 (winine-rss-toggle-star "star" "Star or unstar the article shown.")
 (winine-rss-toggle-read "toggle-read" "Mark the article shown unread, or read again.")
 (winine-rss-open-original "open-original" "Open the article's own page in a new winine buffer.")
 (winine-rss-open-external "open-external" "Open the article's own page in the default browser.")
 (winine-rss-mark-all-read "mark-all-read" "Mark every article of the list as read.")
 (winine-rss-scroll-up "page-down" "Scroll the article forward.")
 (winine-rss-scroll-down "page-up" "Scroll the article back."))

(defun winine-rss-edit-feeds ()
  "Visit the subscriptions (`winine-rss-path'); `winine-rss-reload-feeds' applies edits."
  (interactive)
  (find-file-other-window winine-rss-path))

(defun winine-rss-reload-feeds ()
  "Read the subscriptions again and fetch them."
  (interactive)
  (unless (winine-rss--webview)
    (user-error "The reader is not open; run M-x winine-rss"))
  (winine-rss--load-tree)
  (winine-rss--post-init)
  (winine-rss-refresh))

(defvar winine-rss-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'winine-rss-next-article)
    (define-key map "j" #'winine-rss-next-article)
    (define-key map "p" #'winine-rss-previous-article)
    (define-key map "k" #'winine-rss-previous-article)
    (define-key map "s" #'winine-rss-toggle-star)
    (define-key map "u" #'winine-rss-toggle-read)
    (define-key map "o" #'winine-rss-open-original)
    (define-key map (kbd "RET") #'winine-rss-open-original)
    (define-key map "b" #'winine-rss-open-external)
    (define-key map "A" #'winine-rss-mark-all-read)
    (define-key map (kbd "SPC") #'winine-rss-scroll-up)
    (define-key map (kbd "DEL") #'winine-rss-scroll-down)
    (define-key map (kbd "S-SPC") #'winine-rss-scroll-down)
    (define-key map "r" #'winine-rss-refresh)
    (define-key map "g" #'winine-rss-refresh)
    (define-key map "G" #'winine-rss-reload-feeds)
    (define-key map "e" #'winine-rss-edit-feeds)
    ;; These would navigate the reader's webview away from the reader.
    (define-key map "f" #'undefined)
    ;; Remaps do not chain, so these replace the parent map's own remaps.
    (define-key map [remap revert-buffer] #'winine-rss-refresh)
    (define-key map [remap scroll-up-command] #'winine-rss-scroll-up)
    (define-key map [remap scroll-down-command] #'winine-rss-scroll-down)
    (define-key map [remap next-line] #'winine-rss-next-article)
    (define-key map [remap previous-line] #'winine-rss-previous-article)
    map))

(define-derived-mode winine-rss-mode winine-browser-mode "WININE-RSS"
  "Major mode of the buffer whose window the winine RSS reader covers.
The reader is a web page; these keys drive it while the focus is in Emacs.
\\<winine-rss-mode-map>\\[winine-browser-focus-webpage] moves the focus into the page, where the same keys work.

\\{winine-rss-mode-map}"
  (add-hook 'kill-buffer-hook #'winine-rss--cleanup nil t)
  (add-hook 'change-major-mode-hook #'winine-rss--cleanup nil t))

(defun winine-rss--ensure-path ()
  "Make sure `winine-rss-path' names an existing file or directory."
  (unless winine-rss-path
    (let ((path (expand-file-name
                 (read-file-name "elfeed.org file, or a directory of such files: "))))
      ;; Saving fails under emacs -Q; the session still uses the answer.
      (condition-case nil
          (customize-save-variable 'winine-rss-path path)
        (error (setq winine-rss-path path)))))
  (unless (file-exists-p winine-rss-path)
    (user-error "`winine-rss-path' does not exist: %s" winine-rss-path)))

;;;###autoload
(defun winine-rss ()
  "Open the RSS reader, or go back to it.
The subscriptions are read from `winine-rss-path', an elfeed-org file or a
directory of such files."
  (interactive)
  (let ((buffer (get-buffer winine-rss--buffer-name)))
    (if (and buffer (buffer-local-value 'winine-browser--local-id buffer))
        (switch-to-buffer buffer)
      (winine-rss--ensure-path)
      (winine-rss--db)
      (winine-rss--load-tree)
      (winine-browser--check-user-data-dir)
      (let* ((frame (selected-frame))
             (id (winine-browser--webview-new frame))
             (buffer (get-buffer-create winine-rss--buffer-name)))
        (winine-native-webview-set-on-web-message id #'winine-rss--on-message)
        (winine-native-webview-set-on-new-window-requested
         id #'winine-browser--on-new-window-requested)
        (winine-native-webview-set-on-focus
         id (lambda (focused) (winine-browser--on-focus-change focused buffer)))
        (with-current-buffer buffer
          (winine-rss-mode)
          (setq-local winine-browser--local-id id
                      winine-browser--local-frame frame
                      winine-browser--local-special t))
        (when winine-rss-refresh-interval
          (setq winine-rss--timer
                (run-with-timer winine-rss-refresh-interval winine-rss-refresh-interval
                                #'winine-rss-refresh)))
        (winine-native-webview-load id (winine-rss--page-url)
                                 (lambda (_title _url) (switch-to-buffer buffer)))))))

(provide 'winine-rss)

;;; winine-rss.el ends here

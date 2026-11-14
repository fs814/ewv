;; -*- lexical-binding: t; -*-

(defgroup ewv-browser nil
  "Browser based on ewv"
  :link '(info-link :tag "Info Manual" "(ewv)")
  :link '(url-link :tag "Website" "https://github.com/heartnheart/ewv")
  :group 'tools
  :prefix "ewv-browser")

(require 'ewv-core)
(require 'json)


(defcustom eb/default-url "https://www.baidu.com" "ewv-browser-open-url 默认打开的 url")

(defcustom eb/browser-executable-folder nil
  "传递给 CreateCoreWebView2EnvironmentWithOptions 的参数。
See https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/webview2-idl?view=webview2-1.0.3800.47#createcorewebview2environmentwithoptions")

(defcustom eb/user-data-folder nil
  "传递给 CreateCoreWebView2EnvironmentWithOptions 的参数。
See https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/webview2-idl?view=webview2-1.0.3800.47#createcorewebview2environmentwithoptions")

(defcustom eb/are-browser-extensions-enabled t
  "传递给 CreateCoreWebView2EnvironmentWithOptions 的参数。
See https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/webview2-idl?view=webview2-1.0.3800.47#createcorewebview2environmentwithoptions")

;; 即使是 64 位 edge.exe 也会安装到 Program Files (x86)
(defcustom eb/edge-path "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe"
  "使用 edge 来编辑 ewv-browser 的 user data folder。注意 edge 的版本需要跟 webview2 runtime 的版本匹配。")

(defvar-local eb//local-id nil "底层 webview 对应的 id")
(defvar-local eb//local-frame nil "底层 webview 所属 parent HWND 对应的 emacs frame")
(defvar-local eb//local-pinned nil "当前 tab 是否被 pin")
(defvar-local eb//local-special nil
  "Non-nil when the webview shows a page of ewv itself (the RSS reader), not a
web page.  Such a buffer is left out of pins and saved sessions: reopening its
URL would give the bare page without the Lisp side that drives it.")

(defcustom eb/color-scheme nil
  "Whether pages are told to prefer a light or a dark color scheme.
nil leaves it to Windows.  `emacs' follows the background of the frame the
webview is created in.  It is a setting of the browser profile, so the last
webview created decides for all of them."
  :type '(choice (const :tag "Follow Windows" nil)
                 (const :tag "Follow the Emacs theme" emacs)
                 (const :tag "Light" light)
                 (const :tag "Dark" dark)))

(defvar eb/webview-created-functions nil
  "Functions called with the webview id and the buffer of each new browser tab,
before its first page loads.  ewv-plugins uses it to install its scripts.")

(defvar eb//all-buffers nil "所有 ewv-browser buffer")
(defvar eb//session-urls nil "记录当前 session ewv-browser buffer")


(defvar eb//all-pinned-tabs nil "记录所有被 pin 的 tabs")

(defun eb//get-user-data-dir()
  (or (and eb/user-data-folder (expand-file-name "EBWebView"  eb/user-data-folder))
      (expand-file-name "emacs.exe.WebView2\\EBWebView" invocation-directory)))

(defvar eb//pin-file (expand-file-name "ewv-browser-pin.el" (eb//get-user-data-dir)))

(defun eb//read-pin-file()
  (when (file-exists-p eb//pin-file)
    (with-temp-buffer
      (insert-file-contents eb//pin-file)
      (eval-buffer))))

(defun eb//save-pin-file()
  (setq eb//all-pinned-tabs
        (cl-loop for buf in (eb//tab-buffers)
                 if (buffer-local-value 'eb//local-pinned buf)
                 collect (ent/webview-get-url (buffer-local-value 'eb//local-id buf))))
  ;; This runs from `kill-emacs-hook', where an error stops Emacs from exiting
  ;; and asks the user what to do.  The user data dir only exists once a
  ;; webview has been created, so a session that never opened one (only the
  ;; dx12 demos, say) has nowhere to write: skip when there is nothing to
  ;; record, create the directory otherwise.
  (when (or eb//all-pinned-tabs (file-exists-p eb//pin-file))
    (make-directory (file-name-directory eb//pin-file) t)
    (with-temp-file eb//pin-file
      (insert ";; -*- lexical-binding: t; -*-\n")
      (insert (format "(setq ewv-browser--all-pinned-tabs '%S)" eb//all-pinned-tabs)))))

(eb//read-pin-file)
(add-hook 'kill-emacs-hook #'eb//save-pin-file)


(defun eb/reopen-all-pinned-tabs()
  (interactive)
  (dolist (url eb//all-pinned-tabs)
    (eb/open-url url t)))

;;; session
;; Like appine, remember the tabs that were open when Emacs exited.  Restoring
;; is a command, not automatic: put `ewv-browser-restore-session' on
;; `emacs-startup-hook' to get the tabs back at startup.
(defun eb//tab-buffers ()
  "The live browser buffers that show web pages, oldest first."
  (cl-remove-if-not (lambda (buf)
                      (and (buffer-live-p buf)
                           (buffer-local-value 'eb//local-id buf)
                           (not (buffer-local-value 'eb//local-special buf))))
                    (reverse eb//all-buffers)))

(defun eb//session-file ()
  (expand-file-name "ewv-browser-session.el" (eb//get-user-data-dir)))

(defun eb//save-session ()
  "Record the URLs of the open tabs.  Runs from `kill-emacs-hook'."
  (let ((urls (delete "about:blank"
                      (mapcar (lambda (buf)
                                (ent/webview-get-url (buffer-local-value 'eb//local-id buf)))
                              (eb//tab-buffers))))
        (file (eb//session-file)))
    ;; As for the pin file: an error here would stop Emacs from exiting, and
    ;; the directory only exists once a webview has been created.
    (when (or urls (file-exists-p file))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (prin1 urls (current-buffer))))))

(add-hook 'kill-emacs-hook #'eb//save-session)

(defun eb/restore-session ()
  "Reopen the tabs that were open when Emacs last exited.
Tabs that are already open (reopened pinned tabs, say) are not duplicated."
  (interactive)
  (let ((urls (and (file-exists-p (eb//session-file))
                   (with-temp-buffer
                     (insert-file-contents (eb//session-file))
                     (ignore-errors (read (current-buffer))))))
        (open (mapcar (lambda (buf)
                        (ent/webview-get-url (buffer-local-value 'eb//local-id buf)))
                      (eb//tab-buffers)))
        (count 0))
    (dolist (url urls)
      (when (and (stringp url) (not (member url open)))
        (eb/open-url url)
        (cl-incf count)))
    (message "ewv-browser: restored %d tab%s" count (if (= count 1) "" "s"))))

(defvar eb//environment nil "假设 ewv-browser 共享一个 webview environment")


;; TODO emacs-module-rs 目前不支持接受变长参数
(defun ent/environment-new (&rest args)
  (ent/environment-new1 args))

(defun eb//ensure-environment()
  (setq eb//environment (or eb//environment (ent/environment-new
                                             :browser-executable-folder eb/browser-executable-folder
                                             :user-data-folder eb/user-data-folder
                                             :are-browser-extensions-enabled eb/are-browser-extensions-enabled))))

(defun eb//webview-new(frame)
  (eb//ensure-environment)
  (let ((id (ent/webview-new frame eb//environment)))
    (when eb/color-scheme
      (ent/webview-set-color-scheme
       id (symbol-name (if (eq eb/color-scheme 'emacs)
                           (frame-parameter frame 'background-mode)
                         eb/color-scheme))))
    id))

(defun eb//check-user-data-dir ()
  "Signal an error if another process holds the browser profile."
  (when (and (file-exists-p (expand-file-name "lockfile" (eb//get-user-data-dir)))
             (length= eb//all-buffers 0))
    (user-error "User Data Dir %s is locked" (eb//get-user-data-dir))))

(defun eb/focus-webpage ()
  (interactive)
  (when eb//local-id
    (ent/webview-focus eb//local-id)
    (message "Focus moved to webpage")))

(defun eb/toggle-visibility ()
  (interactive)
  (ent/webview-set-visible eb//local-id
                           (not (ent/webview-is-visible eb//local-id))))

(defun eb/load-new-url (url)
  (interactive "sEdit Url: ")
  (eb//load eb//local-id url (current-buffer)))

(defun eb/load-new-file (file)
  (interactive "fFile: ")
  (eb//load eb//local-id file (current-buffer)))


(defun eb//enable-global-hooks ()
  (add-hook 'window-configuration-change-hook #'eb//monitor-window-configuration-change)
  (add-hook 'delete-frame-functions #'eb//delete-frame-function))

(defun eb//disable-global-hooks ()
  (remove-hook 'window-configuration-change-hook #'eb//monitor-window-configuration-change)
  (remove-hook 'delete-frame-functions #'eb//delete-frame-function))

(defun eb//register-buffer (buffer)
  (cl-pushnew buffer eb//all-buffers)
  ;; (ec//print "register buffer len = %S" eb//all-buffers)
  (when (= (length eb//all-buffers) 1)
    (eb//enable-global-hooks)))

(defun eb//unregister-buffer ()
  (ent/webview-close eb//local-id)
  (setq eb//all-buffers (cl-remove (current-buffer) eb//all-buffers))
  ;; (ec//print "unregister buffer len = %S" eb//all-buffers)
  (when (<= (length eb//all-buffers) 0)
    (eb//disable-global-hooks)
    (setq eb//environment nil)))

(defun eb//monitor-window-configuration-change1()
  (dolist (wind (window-list))
    ;; NOTE (window-old-buffer) 在 window-state-change-hook 中总是返回跟 new-buf 一样的值, 所以只能用 window-configuration-change-hook
    (with-current-buffer (window-buffer wind)
      ;; (ec//print "monitor wind conf change in buffer %S" (current-buffer))
      (when-let* ((bounds (ec//get-window-edges wind))
                  (id eb//local-id)
                  (frame (window-frame wind)))
        (ent/webview-reparent id frame)
        (setq-local eb//local-frame frame)
        (ent/webview-resize id bounds)
        (ent/webview-set-visible id t))))

  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and eb//local-id  (not (get-buffer-window buf t)))
        (ent/webview-set-visible eb//local-id nil)))))

(defvar eb//monitor-window-configuration-change-timer nil)
(defun eb//monitor-window-configuration-change()
  (when eb//monitor-window-configuration-change-timer
    ;; cancel 一个已经执行过的好像也没错
    (cancel-timer eb//monitor-window-configuration-change-timer))
  (setq eb//monitor-window-configuration-change-timer
        (run-with-idle-timer 0 nil #'eb//monitor-window-configuration-change1)))

;; NOTE window-configuration-change-hook NOT work for window deletion
(defun eb//delete-frame-function(frame)
  (when-let* ((safe-frame (car-safe (remove frame (frame-list)))))
    (dolist (buf eb//all-buffers)
      (with-current-buffer buf
        (when (eq frame eb//local-frame)
          (ent/webview-reparent eb//local-id safe-frame)
          (ent/webview-set-visible eb//local-id nil)
          (setq-local eb//local-frame safe-frame))))))

(defun eb//normalize-url(url)
  (if (or (string-prefix-p "https://" url)
          (string-prefix-p "http://" url)
          (string-prefix-p "chrome://" url)
          (string-prefix-p "file://" url)
          (string-prefix-p "chrome-extension://" url)
          (string-prefix-p "extension://" url)
          (string-prefix-p "edge://" url)
          (string-prefix-p "about:blank" url)
          )
      url
    (if (file-exists-p url)
        (concat "file://" (expand-file-name url))
      (concat "https://" url))))

(defun eb//format-title(id title)
  (format "*ewv-buffer-%d-%s*" id title))

(defun eb//load (id url buffer)
  (ent/webview-load id
                    (eb//normalize-url url)
                    (lambda (title url)
                      (with-current-buffer buffer
                        (rename-buffer (eb//format-title id title)))
                      (switch-to-buffer buffer))))

(defun eb//on-new-window-requested(url features)
  (ec//print "eb new-window-requrest url = %S" url)
  (ec//print "                       features = %S" features)
  (cond
   ;; 有些 link 如百度新闻里的会要求访问 about:blank
   ((string= url "about:blank") t)
   ;; 可能是 popup
   ((plist-get features :has-position) nil)
   (t (eb/open-url url) t)
   ))

(defun eb//on-focus-change(focused buffer)
  "When the page gets the keyboard focus (a click on it), select its window."
  (when focused
    (let ((w (get-buffer-window buffer)))
      (and (window-live-p w)
           (not (eq w (selected-window)))
           (select-window w)))))

(defun eb/open-url (url &optional pin)
  "在当前 frame 新建一个 buffer 打开指定的 url。"
  (interactive (list (read-string (format "URL [%s]: " eb/default-url))))
  (eb//check-user-data-dir)
  (when (string-empty-p url)
    (setq url eb/default-url))
  (setq url (eb//normalize-url url))

  (let* ((frame (selected-frame))
         (eb-id (eb//webview-new frame))
         (eb-buffer-name (format "*ewv-browser-%d*" eb-id))
         (eb-buffer (get-buffer-create eb-buffer-name)))

    (ent/webview-set-on-new-window-requested eb-id #'eb//on-new-window-requested)
    ;; update tab-bar
    (ent/webview-set-on-history-changed eb-id #'(lambda () (with-current-buffer eb-buffer (rename-buffer (eb//format-title eb//local-id (ent/webview-get-document-title eb//local-id))))))
    (ent/webview-set-on-focus eb-id (lambda (focused) (eb//on-focus-change focused eb-buffer)))
    (run-hook-with-args 'eb/webview-created-functions eb-id eb-buffer)
    (with-current-buffer eb-buffer
      (eb/mode)
      (setq-local eb//local-id eb-id)
      (setq-local eb//local-frame frame)
      (setq-local eb//local-pinned pin)
      (eb//load eb//local-id url eb-buffer))))

(defun eb/open-file (file)
  (interactive "fFile: ")
  (when (and (featurep 'recentf) (file-regular-p file))
    (recentf-add-file (expand-file-name file)))
  (eb/open-url (eb//normalize-url file)))

(defun eb/open-file-from-recentf ()
  "Open a recently visited file in a new ewv buffer."
  (interactive)
  (if (bound-and-true-p recentf-list)
      (eb/open-file
       (expand-file-name
        (completing-read "Recent file: " (mapcar #'abbreviate-file-name recentf-list)
                         nil t nil 'file-name-history)))
    (call-interactively #'eb/open-file)))

(defun eb/kill-all()
  "关闭 ewv-browser 所有 buffer"
  (interactive)
  (dolist (buf eb//all-buffers)
    (kill-buffer buf)))


(defun eb/open-session-in-edge()
  (interactive)
  (when (file-executable-p eb/edge-path)
    (setq eb//session-urls (mapcar (lambda (buf) (ent/webview-get-url (buffer-local-value 'eb//local-id buf)))
                                   (eb//tab-buffers)))
    (eb/kill-all)
    (let ((user-data-dir (eb//get-user-data-dir)))
      ;; webview2 退出之后还需要一段时间才会完整退出
      (while (file-exists-p (expand-file-name "lockfile" user-data-dir))
        (sit-for 0.5))
      (set-process-sentinel
       (apply #'start-process "*Edge*" nil eb/edge-path
                      (format "--user-data-dir=%s" user-data-dir)
                      ;; (car-safe eb//session-urls)
                      eb//session-urls
                      )
       (lambda (proc event)
         ;; edge 退出之后还需要一段时间才会完整退出
         (while (file-exists-p (expand-file-name "lockfile" user-data-dir))
           (sit-for 0.5))
         (dolist (url eb//session-urls)
           (eb/open-url url))
         )
       ))))

(defvar eb/tool-bar-map
  (let ((tool-bar-map (make-sparse-keymap)))
    ;; Add specific items to this new map
    tool-bar-map)
  "Custom tool bar map for Lisp mode.")



(defun eb/go-forward()
  (interactive)
  (ent/webview-go-forward eb//local-id))

(defun eb/go-back()
  (interactive)
  (ent/webview-go-back eb//local-id))

(defun eb/open-history ()
  (interactive)
  (eb/open-url "edge://history"))

(defun eb/pin-tab ()
  (interactive)
  (setq-local eb//local-pinned t)
  (force-mode-line-update))

(defun eb/unpin-tab ()
  (interactive)
  (setq-local eb//local-pinned nil)
  (force-mode-line-update))

;;; driving the page while the focus is in Emacs
;; The counterpart of appine's "use it like a buffer": the usual Emacs keys for
;; scrolling, searching and copying act on the page (see `ewv-browser-mode-map').
(defun eb//js (js)
  "Run JS in the current buffer's page, ignoring its result."
  (unless eb//local-id
    (user-error "Not an ewv-browser buffer"))
  (ent/webview-eval-js eb//local-id js #'ignore))

(defun eb/reload ()
  "Reload the page."
  (interactive)
  (ent/webview-reload eb//local-id))

(defun eb/scroll-up ()
  "Scroll the page forward by almost a screen."
  (interactive)
  (eb//js "window.scrollBy(0, window.innerHeight * 0.9)"))

(defun eb/scroll-down ()
  "Scroll the page back by almost a screen."
  (interactive)
  (eb//js "window.scrollBy(0, -window.innerHeight * 0.9)"))

(defun eb/scroll-line-up ()
  "Scroll the page forward a little."
  (interactive)
  (eb//js "window.scrollBy(0, 60)"))

(defun eb/scroll-line-down ()
  "Scroll the page back a little."
  (interactive)
  (eb//js "window.scrollBy(0, -60)"))

(defun eb/scroll-to-top ()
  "Scroll to the top of the page."
  (interactive)
  (eb//js "window.scrollTo(0, 0)"))

(defun eb/scroll-to-bottom ()
  "Scroll to the bottom of the page."
  (interactive)
  (eb//js "window.scrollTo(0, document.documentElement.scrollHeight)"))

(defvar-local eb//find-string nil "The last string searched for in this page.")

(defun eb/find (string &optional backward)
  "Find the next occurrence of STRING in the page, or the previous if BACKWARD.
The search wraps around.  Repeat with `ewv-browser-find-next' and
`ewv-browser-find-previous'."
  (interactive (list (read-string (if eb//find-string
                                      (format "Find in page (default %s): " eb//find-string)
                                    "Find in page: ")
                                  nil nil eb//find-string)))
  (when (or (null string) (string-empty-p string))
    (user-error "Nothing to search for"))
  (setq eb//find-string string)
  (eb//js (format "window.find(%s, false, %s, true)"
                  (json-encode-string string) (if backward "true" "false"))))

(defun eb/find-next ()
  "Find the next occurrence of the last search string."
  (interactive)
  (if eb//find-string (eb/find eb//find-string) (call-interactively #'eb/find)))

(defun eb/find-previous ()
  "Find the previous occurrence of the last search string."
  (interactive)
  (if eb//find-string (eb/find eb//find-string t) (call-interactively #'eb/find)))

(defun eb/copy-selection ()
  "Copy the text selected in the page to the kill ring."
  (interactive)
  (ent/webview-execute-script
   eb//local-id "window.getSelection().toString()"
   (lambda (json)
     (let ((text (ignore-errors (json-read-from-string json))))
       (if (and (stringp text) (not (string-empty-p text)))
           (progn (kill-new text)
                  (message "Copied %d characters from the page" (length text)))
         (message "Nothing is selected in the page"))))))

(defun eb/copy-url ()
  "Copy the URL of the page to the kill ring."
  (interactive)
  (let ((url (ent/webview-get-url eb//local-id)))
    (kill-new url)
    (message "%s" url)))

(defun eb/next-tab (&optional n)
  "Switch to the Nth next ewv-browser buffer, in the order they were opened."
  (interactive "p")
  (let* ((tabs (cl-remove-if-not #'buffer-live-p (reverse eb//all-buffers)))
         (i (cl-position (current-buffer) tabs)))
    (when tabs
      (switch-to-buffer (nth (mod (+ (or i -1) (or n 1)) (length tabs)) tabs)))))

(defun eb/previous-tab (&optional n)
  "Switch to the Nth previous ewv-browser buffer."
  (interactive "p")
  (eb/next-tab (- (or n 1))))

;;; org-mode
(defcustom eb/use-for-org-links nil
  "Non-nil to open the web and file links of Org buffers in ewv.
File links are taken only for the types in `ewv-browser-org-file-extensions'."
  :type 'boolean)

(defcustom eb/org-file-extensions
  '("pdf" "html" "htm" "svg" "png" "jpg" "jpeg" "gif" "webp" "mp4" "webm" "mp3" "wav" "ogg")
  "Extensions of the files an Org file link opens in ewv.
Keep it to what the webview can show; it downloads anything else."
  :type '(repeat string))

(defun eb/toggle-use-for-org-links ()
  "Toggle opening the links of Org buffers in ewv."
  (interactive)
  (setq eb/use-for-org-links (not eb/use-for-org-links))
  (message "Org links open in ewv: %s" (if eb/use-for-org-links "on" "off")))

(declare-function org-element-context "org-element")
(declare-function org-element-type "org-element")
(declare-function org-element-property "org-element")

(defun eb//org-open-at-point ()
  "Open the Org link at point in ewv, if `ewv-browser-use-for-org-links' says so.
On `org-open-at-point-functions': returning nil leaves the link to Org."
  (when eb/use-for-org-links
    (let ((context (ignore-errors (org-element-context))))
      (when (eq (org-element-type context) 'link)
        (let ((type (org-element-property :type context))
              (path (org-element-property :path context)))
          (cond
           ((member type '("http" "https"))
            (eb/open-url (concat type ":" path))
            t)
           ((and (equal type "file")
                 (member (downcase (or (file-name-extension path) "")) eb/org-file-extensions)
                 (file-exists-p path))
            (eb/open-file path)
            t)))))))

(with-eval-after-load 'org
  (add-hook 'org-open-at-point-functions #'eb//org-open-at-point))

(tool-bar-local-item "left-arrow" 'eb/go-back 'eb/go-back eb/tool-bar-map :enable '(ent/webview-can-go-back eb//local-id))

(tool-bar-local-item "right-arrow" 'eb/go-forward 'eb/go-forward eb/tool-bar-map :enable '(ent/webview-can-go-forward eb//local-id))

(define-key-after eb/tool-bar-map [eb/open-session-in-edge-local]
  `(menu-item "Open url" eb//open-default-url
              :image (image :type svg :file ,(expand-file-name "ewv.svg" ec//src-dir) :height ,(tool-bar-height nil t) :scale 0.9)
              :help "Open default url in in new buffer"))

(define-key-after eb/tool-bar-map [eb/open-history]
  `(menu-item "Open history" eb/open-history
              :image (image :type svg :file ,(expand-file-name "history.svg" ec//src-dir) :height ,(tool-bar-height nil t) :scale 0.9)
              :help "Open history in new buffer"))

(define-key-after eb/tool-bar-map [eb/open-session-in-edge]
  `(menu-item "Open in Edge" eb/open-session-in-edge
              :image (image :type svg :file ,(expand-file-name "edge.svg" ec//src-dir) :height ,(tool-bar-height nil t) :scale 0.7)
              :help "Open all webpages in Edge"))

(define-key-after eb/tool-bar-map [eb/pin-tab]
  `(menu-item "Open in Edge" eb/pin-tab
              :image (image :type svg :file ,(expand-file-name "pin.svg" ec//src-dir) :height ,(tool-bar-height nil t) :scale 0.7)
              :visible (not eb//local-pinned)
              :help "Pin current url"))

(define-key-after eb/tool-bar-map [eb/unpin-tab]
  `(menu-item "Open in Edge" eb/unpin-tab
              :image (image :type svg :file ,(expand-file-name "unpin.svg" ec//src-dir) :height ,(tool-bar-height nil t) :scale 0.7)
              :visible eb//local-pinned
              :help "Unpin current url"))

(defvar eb/mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "i") #'eb/focus-webpage)
    (define-key map (kbd "t") #'eb/toggle-visibility)
    (define-key map (kbd "e") #'eb/load-new-url)
    (define-key map (kbd "f") #'eb/load-new-file)
    (define-key map (kbd "r") #'eb/reload)
    (define-key map (kbd "w") #'eb/copy-url)
    (define-key map [remap revert-buffer] #'eb/reload)
    (define-key map [remap scroll-up-command] #'eb/scroll-up)
    (define-key map [remap scroll-down-command] #'eb/scroll-down)
    (define-key map [remap next-line] #'eb/scroll-line-up)
    (define-key map [remap previous-line] #'eb/scroll-line-down)
    (define-key map [remap beginning-of-buffer] #'eb/scroll-to-top)
    (define-key map [remap end-of-buffer] #'eb/scroll-to-bottom)
    (define-key map [remap isearch-forward] #'eb/find)
    (define-key map [remap isearch-backward] #'eb/find-previous)
    (define-key map [remap kill-ring-save] #'eb/copy-selection)
    (define-key map (kbd "C-c C-s") #'eb/find-next)
    (define-key map (kbd "C-c C-r") #'eb/find-previous)
    (define-key map (kbd "C-c C-f") #'eb/go-forward)
    (define-key map (kbd "C-c C-b") #'eb/go-back)
    (define-key map (kbd "C-c C-n") #'eb/next-tab)
    (define-key map (kbd "C-c C-p") #'eb/previous-tab)
    map))

(define-derived-mode eb/mode special-mode "EWV-Browser"
  (use-local-map eb/mode-map)
  ;; window-configuration-change-hook 运行的时候 frame 已经删除了，此时再 reparent 会 panic
  ;; TODO 这个 hook 也不保证一定在 frame 删除之前调用
  (add-hook 'kill-buffer-hook #'eb//unregister-buffer nil t)
  (add-hook 'change-major-mode-hook #'eb//unregister-buffer nil t)
  (setq-local tool-bar-map eb/tool-bar-map)
  (eb//register-buffer (current-buffer)))

(defun eb//open-default-url ()
  (interactive)
  (eb/open-url eb/default-url))

(define-key-after global-map [tool-bar eb/open-default-url]
  `(menu-item "Open url" eb//open-default-url
              :image (image :type svg :file ,(expand-file-name "ewv.svg" ec//src-dir) :height ,(tool-bar-height nil t) :scale 0.9)
              :help "Open default url in in buffer"))


(provide 'ewv-browser)

;; Local Variables:
;; read-symbol-shorthands: (("eb/" . "ewv-browser-")
;;                          ("eb//" . "ewv-browser--")
;;                          ("ent/" . "ewv-native-")
;;                          ("ec//" . "ewv-core--")
;;                          )
;; coding: utf-8-unix
;; End:

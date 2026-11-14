;;; ewv-plugins.el --- Link hints and a selection assistant for ewv-browser  -*- lexical-binding: t; -*-

;;; Commentary:

;; The counterparts of appine's two browser plugins.  Each is a script in
;; plugins/ that every browser tab runs at the start of every page:
;;
;; Link hints (plugins/link-hints.js)
;;   With the focus in the page, `f' labels the links and controls in view;
;;   type a label to click it.  From Emacs: F (`ewv-plugins-link-hints').
;;
;; Selection assistant (plugins/selection-assistant.js)
;;   Selecting text in a page pops up a toolbar: Translate, Ask AI, Capture,
;;   Search.  The page only asks; Emacs does it:
;;   - Capture runs `org-protocol-capture' with the template
;;     `ewv-plugins-capture-template', so it needs a template like
;;       ("c" "web" entry (file "inbox.org")
;;        "* TODO [[%:link][%:description]]\n\n %i" :immediate-finish t)
;;   - Search opens `ewv-plugins-search-url' + the selection in a new buffer.
;;   - Translate and Ask AI call an OpenAI-compatible chat completions API.
;;     Set `ewv-plugins-ai-model' and `ewv-plugins-ai-key' (or keep the key in
;;     auth-source under the API's host); until then the buttons are hidden.
;;
;; A page must not be able to make Emacs do these things by itself, so every
;; request carries a token that only the injected script knows.

;;; Code:

(require 'cl-lib)
(require 'let-alist)
(require 'url)
(require 'url-http)
(require 'ewv-browser)

(defgroup ewv-plugins nil
  "Scripts ewv-browser adds to every page."
  :group 'ewv
  :prefix "ewv-plugins-")

(defcustom ewv-plugins-link-hints t
  "Non-nil to install the link hints in new browser tabs."
  :type 'boolean)

(defcustom ewv-plugins-link-hints-key "f"
  "The key that shows the link hints while the focus is in the page."
  :type 'string)

(defcustom ewv-plugins-selection-assistant t
  "Non-nil to install the selection assistant in new browser tabs."
  :type 'boolean)

(defcustom ewv-plugins-search-url "https://www.bing.com/search?q="
  "The assistant's Search opens this URL followed by the selected text."
  :type 'string)

(defcustom ewv-plugins-capture-template "c"
  "Keys of the `org-capture-templates' entry the assistant's Capture uses.
nil removes the Capture button."
  :type '(choice (const :tag "No Capture button" nil) string))

(defcustom ewv-plugins-ai-url "https://api.openai.com/v1"
  "Base URL of the OpenAI-compatible API behind Translate and Ask AI."
  :type 'string)

(defcustom ewv-plugins-ai-key nil
  "The API key: a string, or a function returning one.
When nil, the password auth-source has for the host of `ewv-plugins-ai-url'."
  :type '(choice (const :tag "From auth-source" nil) string function))

(defcustom ewv-plugins-ai-model nil
  "The model Translate and Ask AI use; nil removes the two buttons."
  :type '(choice (const :tag "No AI buttons" nil) string))

(defcustom ewv-plugins-ai-translate-prompt "Translate to Chinese. Only output translation."
  "The system prompt of the assistant's Translate."
  :type 'string)

(defconst ewv-plugins--directory
  (expand-file-name "plugins" (file-name-directory (or load-file-name buffer-file-name))))

(defconst ewv-plugins--token
  (secure-hash 'sha256 (format "%s-%s-%s-%s" (random) (current-time) (emacs-pid) (user-uid)))
  "The secret the injected scripts sign their requests with.")

(defun ewv-plugins--script (file config)
  "The source of plugins/FILE as a script run with CONFIG, a JSON object."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents (expand-file-name file ewv-plugins--directory)))
    (format "(function (EWV) {\n%s\n})(%s);" (buffer-string) (ewv-core--json config))))

(defun ewv-plugins--bool (value)
  (if value t :false))

(defun ewv-plugins--install (id buffer)
  "Install the enabled plugins in the new webview ID of BUFFER."
  (when ewv-plugins-link-hints
    (ewv-native-webview-add-script
     id (ewv-plugins--script "link-hints.js" (list :key ewv-plugins-link-hints-key))))
  (when ewv-plugins-selection-assistant
    (ewv-native-webview-set-on-web-message
     id (lambda (_source json) (ewv-plugins--on-message id buffer json)))
    (ewv-native-webview-add-script
     id (ewv-plugins--script
         "selection-assistant.js"
         (list :token ewv-plugins--token
               :translate (ewv-plugins--bool ewv-plugins-ai-model)
               :ask (ewv-plugins--bool ewv-plugins-ai-model)
               :capture (ewv-plugins--bool ewv-plugins-capture-template)
               :search (ewv-plugins--bool ewv-plugins-search-url))))))

(add-hook 'ewv-browser-webview-created-functions #'ewv-plugins--install)

(defun ewv-plugins-link-hints ()
  "Show the link hints in the current buffer's page and move the focus there."
  (interactive)
  (unless ewv-browser--local-id
    (user-error "Not an ewv-browser buffer"))
  (ewv-native-webview-focus ewv-browser--local-id)
  (ewv-native-webview-post-web-message ewv-browser--local-id
                                       (ewv-core--json (list :type "ewv-link-hints"))))

(define-key ewv-browser-mode-map "F" #'ewv-plugins-link-hints)

;;; Requests of the selection assistant

(defun ewv-plugins--capture (url title body)
  (condition-case err
      (progn
        (require 'org-protocol)
        ;; The capture buffer, if the template shows one, needs the keyboard.
        (ewv-native-focus-frame (selected-frame))
        (org-protocol-capture (list :template ewv-plugins-capture-template
                                    :url url :title title :body body)))
    (error (message "ewv capture failed: %s (see `ewv-plugins-capture-template')"
                    (error-message-string err)))))

(defun ewv-plugins--ai-key ()
  (cond ((functionp ewv-plugins-ai-key) (funcall ewv-plugins-ai-key))
        (ewv-plugins-ai-key)
        (t (require 'auth-source)
           (auth-source-pick-first-password
            :host (url-host (url-generic-parse-url ewv-plugins-ai-url))))))

(defun ewv-plugins--ai-messages (kind text messages)
  "The chat messages for a request of KIND about the selection TEXT."
  (vconcat
   (if (equal kind "translate")
       (list (list :role "system" :content ewv-plugins-ai-translate-prompt)
             (list :role "user" :content text))
     (append (list (list :role "system" :content "You are a helpful assistant.")
                   (list :role "user" :content (concat "Context:\n" text))
                   (list :role "assistant" :content "Received."))
             (mapcar (lambda (m)
                       (list :role (if (equal (alist-get 'role m) "assistant") "assistant" "user")
                             :content (format "%s" (alist-get 'content m))))
                     messages)))))

(defun ewv-plugins--ai-answer ()
  "Return (TEXT . ERROR) from the API response in the current buffer."
  (goto-char (point-min))
  (if (not (re-search-forward "\r?\n\r?\n" nil t))
      (cons nil "Empty response")
    (let* ((body (decode-coding-string (buffer-substring-no-properties (point) (point-max))
                                       'utf-8))
           (json (ignore-errors
                   (json-parse-string body :object-type 'alist :array-type 'list
                                      :null-object nil :false-object nil)))
           (message (alist-get 'message (car (alist-get 'choices json))))
           (text (alist-get 'content message))
           (err (alist-get 'error json)))
      (cond ((and (stringp text) (not (string-empty-p text))) (cons text nil))
            ((stringp (alist-get 'message err)) (cons nil (alist-get 'message err)))
            (t (cons nil (format "Unexpected response (HTTP %s)"
                                 (bound-and-true-p url-http-response-status))))))))

(defun ewv-plugins--ai (id request kind text messages)
  "Answer the assistant's REQUEST of KIND in the webview ID."
  (let ((reply (lambda (text error)
                 (ignore-errors      ; the tab may be gone by now
                   (ewv-native-webview-post-web-message
                    id (ewv-core--json
                        (append (list :type "ewv-assistant" :id request)
                                (if error (list :error error) (list :text text))))))))
        (key (ignore-errors (ewv-plugins--ai-key))))
    (cond
     ((not ewv-plugins-ai-model)
      (funcall reply nil "Set `ewv-plugins-ai-model' in Emacs first."))
     ((not (and (stringp key) (not (string-empty-p key))))
      (funcall reply nil "No API key: set `ewv-plugins-ai-key', or add one to auth-source."))
     (t
      (let ((url-request-method "POST")
            (url-request-extra-headers
             `(("Content-Type" . "application/json")
               ("Authorization" . ,(concat "Bearer " key))))
            (url-request-data
             (json-serialize
              (list :model ewv-plugins-ai-model
                    :messages (ewv-plugins--ai-messages kind text messages)))))
        (condition-case err
            (url-retrieve
             (concat (string-trim-right ewv-plugins-ai-url "/+") "/chat/completions")
             (lambda (status)
               (let ((answer (condition-case err
                                 (ewv-plugins--ai-answer)
                               (error (cons nil (error-message-string err))))))
                 ;; An HTTP error still has a body that says why.
                 (when (and (plist-get status :error) (null (cdr answer)) (null (car answer)))
                   (setq answer (cons nil (format "%S" (plist-get status :error)))))
                 (kill-buffer (current-buffer))
                 (funcall reply (car answer) (cdr answer))))
             nil t t)
          (error (funcall reply nil (error-message-string err)))))))))

(defun ewv-plugins--on-message (id buffer json)
  "Handle the web message JSON posted by a page of the webview ID in BUFFER."
  (condition-case err
      (let ((msg (json-parse-string json :object-type 'alist :array-type 'list
                                    :null-object nil :false-object nil)))
        ;; Anything without the token is the page's own chatter (or a forgery).
        (when (and (consp msg) (equal (alist-get 'token msg) ewv-plugins--token))
          (let-alist msg
            (pcase .op
              ("search"
               (when (and ewv-plugins-search-url (stringp .text))
                 ;; Creating a webview pumps window messages; do it later.
                 (run-at-time 0 nil #'ewv-browser-open-url
                              (concat ewv-plugins-search-url (url-hexify-string .text)))))
              ("capture"
               (when (and ewv-plugins-capture-template (stringp .body))
                 (run-at-time 0 nil #'ewv-plugins--capture
                              (format "%s" (or .url "")) (format "%s" (or .title "")) .body)))
              ("assistant"
               (when (and (stringp .id) (stringp .text) (buffer-live-p buffer))
                 (ewv-plugins--ai id .id .kind .text .messages)))))))
    (error (message "ewv-plugins: %s" (error-message-string err)))))

(provide 'ewv-plugins)

;;; ewv-plugins.el ends here

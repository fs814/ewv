;;; winine-plugins.el --- Link hints and a selection assistant for winine-browser  -*- lexical-binding: t; -*-

;;; Commentary:

;; The counterparts of appine's two browser plugins.  Each is a script in
;; plugins/ that every browser tab runs at the start of every page:
;;
;; Link hints (plugins/link-hints.js)
;;   With the focus in the page, `f' labels the links and controls in view;
;;   type a label to click it.  From Emacs: F (`winine-plugins-link-hints').
;;
;; Selection assistant (plugins/selection-assistant.js)
;;   Selecting text in a page pops up a toolbar: Translate, Ask AI, Capture,
;;   Search.  The page only asks; Emacs does it:
;;   - Capture runs `org-protocol-capture' with the template
;;     `winine-plugins-capture-template', so it needs a template like
;;       ("c" "web" entry (file "inbox.org")
;;        "* TODO [[%:link][%:description]]\n\n %i" :immediate-finish t)
;;   - Search opens `winine-plugins-search-url' + the selection in a new buffer.
;;   - Translate and Ask AI call an OpenAI-compatible chat completions API.
;;     Set `winine-plugins-ai-model' and `winine-plugins-ai-key' (or keep the key in
;;     auth-source under the API's host); until then the buttons are hidden.
;;
;; A page must not be able to make Emacs do these things by itself, so every
;; request carries a token that only the injected script knows.

;;; Code:

(require 'cl-lib)
(require 'let-alist)
(require 'url)
(require 'url-http)
(require 'winine-browser)

(defgroup winine-plugins nil
  "Scripts winine-browser adds to every page."
  :group 'winine
  :prefix "winine-plugins-")

(defcustom winine-plugins-link-hints t
  "Non-nil to install the link hints in new browser tabs."
  :type 'boolean)

(defcustom winine-plugins-link-hints-key "f"
  "The key that shows the link hints while the focus is in the page."
  :type 'string)

(defcustom winine-plugins-selection-assistant t
  "Non-nil to install the selection assistant in new browser tabs."
  :type 'boolean)

(defcustom winine-plugins-search-url "https://www.bing.com/search?q="
  "The assistant's Search opens this URL followed by the selected text."
  :type 'string)

(defcustom winine-plugins-capture-template "c"
  "Keys of the `org-capture-templates' entry the assistant's Capture uses.
nil removes the Capture button."
  :type '(choice (const :tag "No Capture button" nil) string))

(defcustom winine-plugins-ai-url "https://api.openai.com/v1"
  "Base URL of the OpenAI-compatible API behind Translate and Ask AI."
  :type 'string)

(defcustom winine-plugins-ai-key nil
  "The API key: a string, or a function returning one.
When nil, the password auth-source has for the host of `winine-plugins-ai-url'."
  :type '(choice (const :tag "From auth-source" nil) string function))

(defcustom winine-plugins-ai-model nil
  "The model Translate and Ask AI use; nil removes the two buttons."
  :type '(choice (const :tag "No AI buttons" nil) string))

(defcustom winine-plugins-ai-translate-prompt "Translate to Chinese. Only output translation."
  "The system prompt of the assistant's Translate."
  :type 'string)

(defconst winine-plugins--directory
  (expand-file-name "plugins" (file-name-directory (or load-file-name buffer-file-name))))

(defconst winine-plugins--token
  (secure-hash 'sha256 (format "%s-%s-%s-%s" (random) (current-time) (emacs-pid) (user-uid)))
  "The secret the injected scripts sign their requests with.")

(defun winine-plugins--script (file config)
  "The source of plugins/FILE as a script run with CONFIG, a JSON object."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents (expand-file-name file winine-plugins--directory)))
    (format "(function (WININE) {\n%s\n})(%s);" (buffer-string) (winine-core--json config))))

(defun winine-plugins--bool (value)
  (if value t :false))

(defun winine-plugins--install (id buffer)
  "Install the enabled plugins in the new webview ID of BUFFER."
  (when winine-plugins-link-hints
    (winine-native-webview-add-script
     id (winine-plugins--script "link-hints.js" (list :key winine-plugins-link-hints-key))))
  (when winine-plugins-selection-assistant
    (winine-native-webview-set-on-web-message
     id (lambda (_source json) (winine-plugins--on-message id buffer json)))
    (winine-native-webview-add-script
     id (winine-plugins--script
         "selection-assistant.js"
         (list :token winine-plugins--token
               :translate (winine-plugins--bool winine-plugins-ai-model)
               :ask (winine-plugins--bool winine-plugins-ai-model)
               :capture (winine-plugins--bool winine-plugins-capture-template)
               :search (winine-plugins--bool winine-plugins-search-url))))))

(add-hook 'winine-browser-webview-created-functions #'winine-plugins--install)

(defun winine-plugins-link-hints ()
  "Show the link hints in the current buffer's page and move the focus there."
  (interactive)
  (unless winine-browser--local-id
    (user-error "Not an winine-browser buffer"))
  (winine-native-webview-focus winine-browser--local-id)
  (winine-native-webview-post-web-message winine-browser--local-id
                                       (winine-core--json (list :type "winine-link-hints"))))

(define-key winine-browser-mode-map "F" #'winine-plugins-link-hints)

;;; Requests of the selection assistant

(defun winine-plugins--capture (url title body)
  (condition-case err
      (progn
        (require 'org-protocol)
        ;; The capture buffer, if the template shows one, needs the keyboard.
        (winine-native-focus-frame (selected-frame))
        (org-protocol-capture (list :template winine-plugins-capture-template
                                    :url url :title title :body body)))
    (error (message "winine capture failed: %s (see `winine-plugins-capture-template')"
                    (error-message-string err)))))

(defun winine-plugins--ai-key ()
  (cond ((functionp winine-plugins-ai-key) (funcall winine-plugins-ai-key))
        (winine-plugins-ai-key)
        (t (require 'auth-source)
           (auth-source-pick-first-password
            :host (url-host (url-generic-parse-url winine-plugins-ai-url))))))

(defun winine-plugins--ai-messages (kind text messages)
  "The chat messages for a request of KIND about the selection TEXT."
  (vconcat
   (if (equal kind "translate")
       (list (list :role "system" :content winine-plugins-ai-translate-prompt)
             (list :role "user" :content text))
     (append (list (list :role "system" :content "You are a helpful assistant.")
                   (list :role "user" :content (concat "Context:\n" text))
                   (list :role "assistant" :content "Received."))
             (mapcar (lambda (m)
                       (list :role (if (equal (alist-get 'role m) "assistant") "assistant" "user")
                             :content (format "%s" (alist-get 'content m))))
                     messages)))))

(defun winine-plugins--ai-answer ()
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

(defun winine-plugins--ai (id request kind text messages)
  "Answer the assistant's REQUEST of KIND in the webview ID."
  (let ((reply (lambda (text error)
                 (ignore-errors      ; the tab may be gone by now
                   (winine-native-webview-post-web-message
                    id (winine-core--json
                        (append (list :type "winine-assistant" :id request)
                                (if error (list :error error) (list :text text))))))))
        (key (ignore-errors (winine-plugins--ai-key))))
    (cond
     ((not winine-plugins-ai-model)
      (funcall reply nil "Set `winine-plugins-ai-model' in Emacs first."))
     ((not (and (stringp key) (not (string-empty-p key))))
      (funcall reply nil "No API key: set `winine-plugins-ai-key', or add one to auth-source."))
     (t
      (let ((url-request-method "POST")
            (url-request-extra-headers
             `(("Content-Type" . "application/json")
               ("Authorization" . ,(concat "Bearer " key))))
            (url-request-data
             (json-serialize
              (list :model winine-plugins-ai-model
                    :messages (winine-plugins--ai-messages kind text messages)))))
        (condition-case err
            (url-retrieve
             (concat (string-trim-right winine-plugins-ai-url "/+") "/chat/completions")
             (lambda (status)
               (let ((answer (condition-case err
                                 (winine-plugins--ai-answer)
                               (error (cons nil (error-message-string err))))))
                 ;; An HTTP error still has a body that says why.
                 (when (and (plist-get status :error) (null (cdr answer)) (null (car answer)))
                   (setq answer (cons nil (format "%S" (plist-get status :error)))))
                 (kill-buffer (current-buffer))
                 (funcall reply (car answer) (cdr answer))))
             nil t t)
          (error (funcall reply nil (error-message-string err)))))))))

(defun winine-plugins--on-message (id buffer json)
  "Handle the web message JSON posted by a page of the webview ID in BUFFER."
  (condition-case err
      (let ((msg (json-parse-string json :object-type 'alist :array-type 'list
                                    :null-object nil :false-object nil)))
        ;; Anything without the token is the page's own chatter (or a forgery).
        (when (and (consp msg) (equal (alist-get 'token msg) winine-plugins--token))
          (let-alist msg
            (pcase .op
              ("search"
               (when (and winine-plugins-search-url (stringp .text))
                 ;; Creating a webview pumps window messages; do it later.
                 (run-at-time 0 nil #'winine-browser-open-url
                              (concat winine-plugins-search-url (url-hexify-string .text)))))
              ("capture"
               (when (and winine-plugins-capture-template (stringp .body))
                 (run-at-time 0 nil #'winine-plugins--capture
                              (format "%s" (or .url "")) (format "%s" (or .title "")) .body)))
              ("assistant"
               (when (and (stringp .id) (stringp .text) (buffer-live-p buffer))
                 (winine-plugins--ai id .id .kind .text .messages)))))))
    (error (message "winine-plugins: %s" (error-message-string err)))))

(provide 'winine-plugins)

;;; winine-plugins.el ends here

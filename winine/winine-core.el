;; -*- lexical-binding: t; -*-


;;; load winine_native.dll
;; winine is the C++ build of ewv's native module (README.md here); this is
;; ewv-core.el with the names changed. The DLL is built into this folder by
;; Settings/winbuild/editor/emacsplugin/ewv/build_ewv.ps1 (CMakeLists.txt).
(defvar ec//src-dir (file-name-directory (or load-file-name (buffer-file-name))))
(defvar ec//dll-path (expand-file-name "winine_native.dll" ec//src-dir))

(load ec//dll-path)




(defun ec//get-window-edges(&optional window)
  (window-body-pixel-edges window))

;; 配合 dynamic module 处理异步事件 https://nullprogram.com/blog/2017/02/14/
(define-key special-event-map [language-change]
            (lambda ()
              (interactive)
              (ent/process-events)))

;;; core
(defun ec//get-frame-hwnd (&optional frame)
  "Emasc frame to win32 HWND"
  (string-to-number (frame-parameter (or frame (selected-frame)) 'window-id) 10))


(defun ec//json (object)
  "OBJECT (as `json-serialize' takes it) as JSON text for the native module.
`json-serialize' returns the UTF-8 bytes; the module wants the characters."
  (decode-coding-string (json-serialize object) 'utf-8))

(defun ec//eval-string (string)
  "Called from js. Always convert result to string"
  (condition-case err
      (format "%s" (eval (car (read-from-string (format "(progn %s)" string)))))
    (error (ec//print "winine--eval-string error: %S" err))
    ))


;;; debug
(defun ec/open-task-manager()
  (interactive)
  (ent/webview-open-task-manager)
  )
(defun ec//print(format-exp &rest args)
  (ent/print (apply #'format format-exp args)))

;; https://www.reddit.com/r/emacs/comments/8pbbpe/comment/e0an4xy/?utm_source=share&utm_medium=web3x&utm_name=web3xcss&utm_term=1&utm_content=share_button
(defmacro ec//with-struct-slots (spec-list type inst &rest body)
  (declare (indent 3) (debug (sexp sexp def-body)))
  ;; Transform the spec-list into a cl-symbol-macrolet spec-list.
  (macroexp-let2 nil inst inst
    `(cl-symbol-macrolet
         ,(mapcar (lambda (entry)
                    (let* ((slot-var  (if (listp entry) (car entry) entry))
			   (slot (if (listp entry) (cadr entry) entry))
			   (idx (cl-struct-slot-offset type slot)))
                      (list slot-var `(aref ,inst ,idx))))
                  spec-list)

       (unless (cl-typep ,inst ',type)
	 (error "%s is not a %s" ',inst ',type))

       ,@body)))


(ent/init-frame-thread-hook)

;;; end
(provide 'winine-core)


;; Local Variables:
;; read-symbol-shorthands: (("ec//" . "winine-core--")
;;                          ("ec/" . "winine-core-")
;;                          ("ent/" . "winine-native-")
;;                          )
;; coding: utf-8-unix
;; End:

;; -*- lexical-binding: t; -*-
;;; debug
;; (set-face-attribute 'mode-line nil :height 140)
;; (set-face-attribute 'mode-line-inactive nil :height 140)

(defvar winine-mode-line--webview-list nil)

(defvar winine-mode-line-file
  (expand-file-name "modeline.html" (file-name-directory (or load-file-name (buffer-file-name)))))
(setq winine-mode-line--webview-list nil)
(cl-defstruct winine-mode-line-webview
  ""
  w
  id
  )
(defun winine-mode-line--get-bounds(&optional window)
  (let ((b1 (window-pixel-edges window))
        (b2 (window-body-pixel-edges window)))
    ; (list (nth 0 b1) (nth 3 b2) (nth 2 b1) (nth 3 b1))
    ; offset for debug
    (list (nth 0 b1) (- (nth 3 b2) 20) (nth 2 b1) (- (nth 3 b1) 20))
    ))

(defun winine-mode-line--monitor-window-mode-line()
  (save-excursion
    (save-window-excursion
      (let* ((division (seq-group-by (lambda (e) (window-live-p (winine-mode-line-webview-w e))) winine-mode-line--webview-list))
             (live-list (alist-get t division))
             (dead-list (alist-get nil division))
             )
        (when dead-list
          (cl-loop for w in dead-list
                   do (when (winine-mode-line-webview-id w)
                        (winine-native-webview-close (winine-mode-line-webview-id w))
                        )
                   )
          )
        (when live-list
          (cl-loop for w in live-list
                   do (when (winine-mode-line-webview-id w)
                        (winine-native-webview-resize (winine-mode-line-webview-id w) (winine-mode-line--get-bounds (winine-mode-line-webview-w w)))
                        )
                   )
          )
        (setq winine-mode-line--webview-list live-list)
        (dolist (w (seq-filter (lambda (e) (not (window-minibuffer-p e))) (window-list)))
          (unless (seq-find (lambda (e) (eq w (winine-mode-line-webview-w e)))
                            live-list)
            (winine--print "new window %S " w)
            (let ((new-id (winine-native-webview-new (winine-get-frame-hwnd) (winine-mode-line--get-bounds w))))
              ; (winine-native-webview-set-default-background-color new-id 0 0 0 0)
              (winine-native-webview-load-sync new-id winine-mode-line-file)
              (push (make-winine-mode-line-webview :w w :id new-id) winine-mode-line--webview-list)
              )
            )
          )
        (dolist (wv winine-mode-line--webview-list)
          (winine-with-struct-slots (w id) winine-mode-line-webview wv
                                 (with-current-buffer (window-buffer w)
                                   (winine-native-webview-eval-js id (format "updateModeLine('%s', '%s', '%s:%s', '%s', '%s', '%s' )"
                                                                          (buffer-name)
                                                                          (eq (selected-window) w)
                                                                          (line-number-at-pos) 
                                                                          (current-column)
                                                                          buffer-file-coding-system
                                                                          buffer-read-only 
                                                                          (buffer-modified-p)
                                                                          ) #'identity)
                                   )
                                 )
          )
        )
      )
    )
  )
(add-hook 'window-state-change-hook #'winine-mode-line--monitor-window-mode-line)
(add-hook 'post-command-hook #'winine-mode-line--monitor-window-mode-line)

(provide 'winine-mode-line)
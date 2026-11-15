;;; winine-dx12.el --- Direct3D 12 sample demos in Emacs buffers  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Windows counterpart of appine's Metal demos (`appine-metal-triangle',
;; `appine-metal-raytracing'):
;;
;;   M-x winine-dx12-triangle     a colorful, rotating triangle
;;   M-x winine-dx12-raytracing   a path-traced grid of Cornell boxes (DXR)
;;
;; Each command opens a buffer whose window is covered by a native Direct3D 12
;; view.  The view follows the buffer like any other: split, resize, switch
;; away and back, move it to another frame; killing the buffer closes it.  The
;; native side is src/dx12/ in winine (dx12.cpp, triangle.cpp, raytracing.cpp).
;;
;; The view takes no input, so every key goes to Emacs as usual, and a click on
;; it selects its window.  `q' buries the buffer, `k' kills it, `g' re-syncs
;; the view with its window.
;;
;; When a demo cannot run (for example ray tracing without a DXR-capable GPU)
;; there is no view; the buffer's own text says why.

;;; Code:

(require 'winine-core)

(defgroup winine-dx12 nil
  "Direct3D 12 sample demos based on winine."
  :group 'winine
  :prefix "winine-dx12-")

(defvar-local winine-dx12--id nil
  "Id of this buffer's native Direct3D 12 view.")
(defvar-local winine-dx12--frame nil
  "The frame whose window the native view is currently a child of.")
(defvar-local winine-dx12--demo nil
  "Name of the demo shown in this buffer (\"triangle\" or \"raytracing\").")

(defvar winine-dx12--buffers nil
  "Live buffers that own a native Direct3D 12 view.")

(defconst winine-dx12--titles
  '(("triangle" . "DX12 Triangle")
    ("raytracing" . "DX12 Ray Tracing")))

(defun winine-dx12--sync (&rest _)
  "Place every demo view over the window showing its buffer.
Views whose buffer is not displayed are hidden (and stop rendering)."
  (dolist (buffer winine-dx12--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when winine-dx12--id
          (let ((window (get-buffer-window buffer t)))
            (if (not window)
                (winine-native-dx12-set-visible winine-dx12--id nil)
              (let ((frame (window-frame window)))
                (unless (eq frame winine-dx12--frame)
                  (winine-native-dx12-reparent winine-dx12--id frame)
                  (setq winine-dx12--frame frame))
                (winine-native-dx12-resize winine-dx12--id (winine-core--get-window-edges window))
                (winine-native-dx12-set-visible winine-dx12--id t)))))))))

(defun winine-dx12--delete-frame (frame)
  "Move views off FRAME before it goes: its child windows die with it."
  (when-let* ((other (car (remq frame (frame-list)))))
    (dolist (buffer winine-dx12--buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and winine-dx12--id (eq winine-dx12--frame frame))
            (winine-native-dx12-set-visible winine-dx12--id nil)
            (winine-native-dx12-reparent winine-dx12--id other)
            (setq winine-dx12--frame other)))))))

(defun winine-dx12--enable-hooks ()
  (add-hook 'window-configuration-change-hook #'winine-dx12--sync)
  (add-hook 'window-size-change-functions #'winine-dx12--sync)
  (add-hook 'delete-frame-functions #'winine-dx12--delete-frame))

(defun winine-dx12--disable-hooks ()
  (remove-hook 'window-configuration-change-hook #'winine-dx12--sync)
  (remove-hook 'window-size-change-functions #'winine-dx12--sync)
  (remove-hook 'delete-frame-functions #'winine-dx12--delete-frame))

(defun winine-dx12--close ()
  "Close the current buffer's native view."
  (when winine-dx12--id
    (winine-native-dx12-close winine-dx12--id)
    (setq winine-dx12--id nil))
  (setq winine-dx12--buffers (delq (current-buffer) winine-dx12--buffers))
  (unless winine-dx12--buffers
    (winine-dx12--disable-hooks)))

(defun winine-dx12--describe (buffer)
  "Write the demo's status into BUFFER; it shows when there is no view."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when winine-dx12--id
        (let ((status (winine-native-dx12-status winine-dx12--id))
              (inhibit-read-only t))
          (erase-buffer)
          (insert (cdr (assoc winine-dx12--demo winine-dx12--titles)) "\n\n" status "\n")
          (if (string-prefix-p "starting" status)
              ;; Still creating the device and pipeline: look again shortly.
              (run-with-timer 0.2 nil #'winine-dx12--describe buffer)
            (when (string-prefix-p "error" status)
              (message "winine-dx12: %s" status))))))))

(defun winine-dx12-status ()
  "Show what the current buffer's demo is doing and how many frames it drew."
  (interactive)
  (unless winine-dx12--id
    (user-error "Not a Direct3D 12 demo buffer"))
  (message "%s (%d frames)"
           (winine-native-dx12-status winine-dx12--id)
           (winine-native-dx12-frame-count winine-dx12--id)))

(defun winine-dx12-refresh ()
  "Re-sync the native views with their windows."
  (interactive)
  (winine-dx12--sync))

(defvar winine-dx12-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'winine-dx12-refresh)
    (define-key map (kbd "s") #'winine-dx12-status)
    (define-key map (kbd "k") #'kill-current-buffer)
    map))

(define-derived-mode winine-dx12-mode special-mode "WININE-DX12"
  "Major mode for buffers showing a native Direct3D 12 demo view."
  (add-hook 'kill-buffer-hook #'winine-dx12--close nil t)
  (add-hook 'change-major-mode-hook #'winine-dx12--close nil t))

(defun winine-dx12--alive-p (buffer)
  "Non-nil if BUFFER has a native view that is starting or running."
  (when-let* ((id (buffer-local-value 'winine-dx12--id buffer)))
    (string-match-p "\\`\\(starting\\|running\\)" (winine-native-dx12-status id))))

(defun winine-dx12--open (demo)
  "Show the Direct3D 12 demo DEMO in its buffer, creating it if needed."
  (let* ((name (format "*winine-dx12-%s*" demo))
         (buffer (get-buffer name)))
    (unless (and buffer (winine-dx12--alive-p buffer))
      (setq buffer (get-buffer-create name))
      (with-current-buffer buffer
        ;; A buffer whose view stopped (an error, or its window went with a
        ;; frame) gets a fresh one.
        (winine-dx12--close)
        (winine-dx12-mode)
        (setq winine-dx12--demo demo
              winine-dx12--frame (selected-frame)
              winine-dx12--id (winine-native-dx12-open demo (selected-frame))))
      (unless winine-dx12--buffers
        (winine-dx12--enable-hooks))
      (push buffer winine-dx12--buffers)
      (winine-dx12--describe buffer))
    (switch-to-buffer buffer)
    (winine-dx12--sync)
    buffer))

;;;###autoload
(defun winine-dx12-triangle ()
  "Open a Direct3D 12 view that draws a colorful, rotating triangle.
The counterpart of `appine-metal-triangle' (see src/dx12/triangle.cpp)."
  (interactive)
  (winine-dx12--open "triangle"))

;;;###autoload
(defun winine-dx12-raytracing ()
  "Open a Direct3D 12 view that path traces a grid of Cornell boxes.
The counterpart of `appine-metal-raytracing' (see src/dx12/raytracing.cpp).  It
needs a GPU with DirectX Raytracing; otherwise the buffer says why it cannot
run.  The image starts noisy and converges as frames accumulate; resizing
restarts it."
  (interactive)
  (winine-dx12--open "raytracing"))

(provide 'winine-dx12)

;;; winine-dx12.el ends here

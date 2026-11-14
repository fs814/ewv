;;; ewv-dx12.el --- Direct3D 12 sample demos in Emacs buffers  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Windows counterpart of appine's Metal demos (`appine-metal-triangle',
;; `appine-metal-raytracing'):
;;
;;   M-x ewv-dx12-triangle     a colorful, rotating triangle
;;   M-x ewv-dx12-raytracing   a path-traced grid of Cornell boxes (DXR)
;;
;; Each command opens a buffer whose window is covered by a native Direct3D 12
;; view.  The view follows the buffer like any other: split, resize, switch
;; away and back, move it to another frame; killing the buffer closes it.  The
;; native side is src/dx12/ in the module (see the README there).
;;
;; The view takes no input, so every key goes to Emacs as usual, and a click on
;; it selects its window.  `q' buries the buffer, `k' kills it, `g' re-syncs
;; the view with its window.
;;
;; When a demo cannot run (for example ray tracing without a DXR-capable GPU)
;; there is no view; the buffer's own text says why.

;;; Code:

(require 'ewv-core)

(defgroup ewv-dx12 nil
  "Direct3D 12 sample demos based on ewv."
  :group 'ewv
  :prefix "ewv-dx12-")

(defvar-local ewv-dx12--id nil
  "Id of this buffer's native Direct3D 12 view.")
(defvar-local ewv-dx12--frame nil
  "The frame whose window the native view is currently a child of.")
(defvar-local ewv-dx12--demo nil
  "Name of the demo shown in this buffer (\"triangle\" or \"raytracing\").")

(defvar ewv-dx12--buffers nil
  "Live buffers that own a native Direct3D 12 view.")

(defconst ewv-dx12--titles
  '(("triangle" . "DX12 Triangle")
    ("raytracing" . "DX12 Ray Tracing")))

(defun ewv-dx12--sync (&rest _)
  "Place every demo view over the window showing its buffer.
Views whose buffer is not displayed are hidden (and stop rendering)."
  (dolist (buffer ewv-dx12--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when ewv-dx12--id
          (let ((window (get-buffer-window buffer t)))
            (if (not window)
                (ewv-native-dx12-set-visible ewv-dx12--id nil)
              (let ((frame (window-frame window)))
                (unless (eq frame ewv-dx12--frame)
                  (ewv-native-dx12-reparent ewv-dx12--id frame)
                  (setq ewv-dx12--frame frame))
                (ewv-native-dx12-resize ewv-dx12--id (ewv-core--get-window-edges window))
                (ewv-native-dx12-set-visible ewv-dx12--id t)))))))))

(defun ewv-dx12--delete-frame (frame)
  "Move views off FRAME before it goes: its child windows die with it."
  (when-let* ((other (car (remq frame (frame-list)))))
    (dolist (buffer ewv-dx12--buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and ewv-dx12--id (eq ewv-dx12--frame frame))
            (ewv-native-dx12-set-visible ewv-dx12--id nil)
            (ewv-native-dx12-reparent ewv-dx12--id other)
            (setq ewv-dx12--frame other)))))))

(defun ewv-dx12--enable-hooks ()
  (add-hook 'window-configuration-change-hook #'ewv-dx12--sync)
  (add-hook 'window-size-change-functions #'ewv-dx12--sync)
  (add-hook 'delete-frame-functions #'ewv-dx12--delete-frame))

(defun ewv-dx12--disable-hooks ()
  (remove-hook 'window-configuration-change-hook #'ewv-dx12--sync)
  (remove-hook 'window-size-change-functions #'ewv-dx12--sync)
  (remove-hook 'delete-frame-functions #'ewv-dx12--delete-frame))

(defun ewv-dx12--close ()
  "Close the current buffer's native view."
  (when ewv-dx12--id
    (ewv-native-dx12-close ewv-dx12--id)
    (setq ewv-dx12--id nil))
  (setq ewv-dx12--buffers (delq (current-buffer) ewv-dx12--buffers))
  (unless ewv-dx12--buffers
    (ewv-dx12--disable-hooks)))

(defun ewv-dx12--describe (buffer)
  "Write the demo's status into BUFFER; it shows when there is no view."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when ewv-dx12--id
        (let ((status (ewv-native-dx12-status ewv-dx12--id))
              (inhibit-read-only t))
          (erase-buffer)
          (insert (cdr (assoc ewv-dx12--demo ewv-dx12--titles)) "\n\n" status "\n")
          (if (string-prefix-p "starting" status)
              ;; Still creating the device and pipeline: look again shortly.
              (run-with-timer 0.2 nil #'ewv-dx12--describe buffer)
            (when (string-prefix-p "error" status)
              (message "ewv-dx12: %s" status))))))))

(defun ewv-dx12-status ()
  "Show what the current buffer's demo is doing and how many frames it drew."
  (interactive)
  (unless ewv-dx12--id
    (user-error "Not a Direct3D 12 demo buffer"))
  (message "%s (%d frames)"
           (ewv-native-dx12-status ewv-dx12--id)
           (ewv-native-dx12-frame-count ewv-dx12--id)))

(defun ewv-dx12-refresh ()
  "Re-sync the native views with their windows."
  (interactive)
  (ewv-dx12--sync))

(defvar ewv-dx12-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'ewv-dx12-refresh)
    (define-key map (kbd "s") #'ewv-dx12-status)
    (define-key map (kbd "k") #'kill-current-buffer)
    map))

(define-derived-mode ewv-dx12-mode special-mode "EWV-DX12"
  "Major mode for buffers showing a native Direct3D 12 demo view."
  (add-hook 'kill-buffer-hook #'ewv-dx12--close nil t)
  (add-hook 'change-major-mode-hook #'ewv-dx12--close nil t))

(defun ewv-dx12--alive-p (buffer)
  "Non-nil if BUFFER has a native view that is starting or running."
  (when-let* ((id (buffer-local-value 'ewv-dx12--id buffer)))
    (string-match-p "\\`\\(starting\\|running\\)" (ewv-native-dx12-status id))))

(defun ewv-dx12--open (demo)
  "Show the Direct3D 12 demo DEMO in its buffer, creating it if needed."
  (let* ((name (format "*ewv-dx12-%s*" demo))
         (buffer (get-buffer name)))
    (unless (and buffer (ewv-dx12--alive-p buffer))
      (setq buffer (get-buffer-create name))
      (with-current-buffer buffer
        ;; A buffer whose view stopped (an error, or its window went with a
        ;; frame) gets a fresh one.
        (ewv-dx12--close)
        (ewv-dx12-mode)
        (setq ewv-dx12--demo demo
              ewv-dx12--frame (selected-frame)
              ewv-dx12--id (ewv-native-dx12-open demo (selected-frame))))
      (unless ewv-dx12--buffers
        (ewv-dx12--enable-hooks))
      (push buffer ewv-dx12--buffers)
      (ewv-dx12--describe buffer))
    (switch-to-buffer buffer)
    (ewv-dx12--sync)
    buffer))

;;;###autoload
(defun ewv-dx12-triangle ()
  "Open a Direct3D 12 view that draws a colorful, rotating triangle.
The counterpart of `appine-metal-triangle' (see src/dx12/triangle/)."
  (interactive)
  (ewv-dx12--open "triangle"))

;;;###autoload
(defun ewv-dx12-raytracing ()
  "Open a Direct3D 12 view that path traces a grid of Cornell boxes.
The counterpart of `appine-metal-raytracing' (see src/dx12/raytracing/).  It
needs a GPU with DirectX Raytracing; otherwise the buffer says why it cannot
run.  The image starts noisy and converges as frames accumulate; resizing
restarts it."
  (interactive)
  (ewv-dx12--open "raytracing"))

(provide 'ewv-dx12)

;;; ewv-dx12.el ends here

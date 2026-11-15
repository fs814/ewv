;;; ewv-vulkan.el --- Khronos Vulkan-Samples in Emacs buffers  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Windows counterpart of appine's `appine-vulkan-sample':
;;
;;   M-x ewv-vulkan-sample    pick one of the Khronos Vulkan-Samples
;;                            (https://github.com/KhronosGroup/Vulkan-Samples)
;;                            and run it in a buffer
;;
;; The samples are a separate library, ewv-vulkan-samples.dll, built once in
;; the ewv checkout (see src/vulkan/README.md):
;;
;;   src\vulkan\fetch_deps.ps1    libraries and assets (about 1.5 GB)
;;   src\vulkan\build.ps1         the library (about 1300 build steps)
;;
;; The view follows its buffer like the Direct3D 12 demos (ewv-dx12.el):
;; split, resize, switch away (it stops drawing) and back, move it to another
;; frame; killing the buffer stops the sample.  Left mouse button and drag go
;; to the sample (most samples orbit their camera with it); keys stay with
;; Emacs.  `k' kills the buffer, `s' shows the status, `g' re-syncs the view.
;;
;; One sample runs at a time: the samples' framework keeps global state.  A
;; sample that needs something this GPU or driver lacks (ray tracing,
;; particular extensions) does not start, and the buffer says why.

;;; Code:

(require 'ewv-core)

(defgroup ewv-vulkan nil
  "Khronos Vulkan-Samples in Emacs buffers, based on ewv."
  :group 'ewv
  :prefix "ewv-vulkan-")

(defcustom ewv-vulkan-library
  (expand-file-name "ewv-vulkan-samples.dll" ewv-core--src-dir)
  "Path of ewv-vulkan-samples.dll, built by src/vulkan/build.ps1."
  :type 'file)

(defcustom ewv-vulkan-samples-root
  (expand-file-name "src/vulkan/Vulkan-Samples" ewv-core--src-dir)
  "The Vulkan-Samples folder: samples/ to list, assets/ and shaders/ to run."
  :type 'directory)

(defvar-local ewv-vulkan--id nil
  "Id of this buffer's native Vulkan view.")
(defvar-local ewv-vulkan--frame nil
  "The frame whose window the native view is currently a child of.")
(defvar-local ewv-vulkan--sample nil
  "Id of the sample shown in this buffer, e.g. \"hello_triangle\".")

(defvar ewv-vulkan--buffers nil
  "Live buffers that own a native Vulkan view.")

(defun ewv-vulkan--samples ()
  "The Khronos Vulkan samples as \"category/id\" strings."
  (let ((root (expand-file-name "samples" ewv-vulkan-samples-root)))
    (unless (file-directory-p root)
      (user-error "No Vulkan samples in %s" root))
    (sort (mapcar (lambda (cmake)
                    (file-relative-name (directory-file-name (file-name-directory cmake)) root))
                  (file-expand-wildcards (expand-file-name "*/*/CMakeLists.txt" root)))
          #'string<)))

(defun ewv-vulkan--sync (&rest _)
  "Place every sample view over the window showing its buffer.
Views whose buffer is not displayed are hidden (and stop drawing)."
  (dolist (buffer ewv-vulkan--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when ewv-vulkan--id
          (let ((window (get-buffer-window buffer t)))
            (if (not window)
                (ewv-native-vks-set-visible ewv-vulkan--id nil)
              (let ((frame (window-frame window)))
                (unless (eq frame ewv-vulkan--frame)
                  (ewv-native-vks-reparent ewv-vulkan--id frame)
                  (setq ewv-vulkan--frame frame))
                (ewv-native-vks-resize ewv-vulkan--id (ewv-core--get-window-edges window))
                (ewv-native-vks-set-visible ewv-vulkan--id t)))))))))

(defun ewv-vulkan--delete-frame (frame)
  "Move views off FRAME before it goes: its child windows die with it."
  (when-let* ((other (car (remq frame (frame-list)))))
    (dolist (buffer ewv-vulkan--buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and ewv-vulkan--id (eq ewv-vulkan--frame frame))
            (ewv-native-vks-set-visible ewv-vulkan--id nil)
            (ewv-native-vks-reparent ewv-vulkan--id other)
            (setq ewv-vulkan--frame other)))))))

(defun ewv-vulkan--enable-hooks ()
  (add-hook 'window-configuration-change-hook #'ewv-vulkan--sync)
  (add-hook 'window-size-change-functions #'ewv-vulkan--sync)
  (add-hook 'delete-frame-functions #'ewv-vulkan--delete-frame))

(defun ewv-vulkan--disable-hooks ()
  (remove-hook 'window-configuration-change-hook #'ewv-vulkan--sync)
  (remove-hook 'window-size-change-functions #'ewv-vulkan--sync)
  (remove-hook 'delete-frame-functions #'ewv-vulkan--delete-frame))

(defun ewv-vulkan--close ()
  "Stop the current buffer's sample and close its view."
  (when ewv-vulkan--id
    (ewv-native-vks-close ewv-vulkan--id)
    (setq ewv-vulkan--id nil))
  (setq ewv-vulkan--buffers (delq (current-buffer) ewv-vulkan--buffers))
  (unless ewv-vulkan--buffers
    (ewv-vulkan--disable-hooks)))

(defun ewv-vulkan--kill-emacs ()
  "Stop every sample before Emacs exits, so none is left mid-frame."
  (dolist (buffer ewv-vulkan--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ewv-vulkan--close)))))

(add-hook 'kill-emacs-hook #'ewv-vulkan--kill-emacs)

(defun ewv-vulkan--describe (buffer)
  "Write the sample's status into BUFFER; it shows when there is no view."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when ewv-vulkan--id
        (let ((status (ewv-native-vks-status ewv-vulkan--id))
              (inhibit-read-only t))
          (erase-buffer)
          (insert "Vulkan sample " ewv-vulkan--sample "\n\n" status "\n")
          (if (string-prefix-p "starting" status)
              ;; Still loading shaders and assets: look again shortly.
              (run-with-timer 0.25 nil #'ewv-vulkan--describe buffer)
            (when (string-prefix-p "error" status)
              (message "ewv-vulkan: %s" status))))))))

(defun ewv-vulkan-status ()
  "Show what the current buffer's sample is doing and how many frames it drew."
  (interactive)
  (unless ewv-vulkan--id
    (user-error "Not a Vulkan sample buffer"))
  (message "%s (%d frames)"
           (ewv-native-vks-status ewv-vulkan--id)
           (ewv-native-vks-frame-count ewv-vulkan--id)))

(defun ewv-vulkan-refresh ()
  "Re-sync the native views with their windows."
  (interactive)
  (ewv-vulkan--sync))

(defvar ewv-vulkan-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'ewv-vulkan-refresh)
    (define-key map (kbd "s") #'ewv-vulkan-status)
    (define-key map (kbd "k") #'kill-current-buffer)
    map))

(define-derived-mode ewv-vulkan-mode special-mode "EWV-Vulkan"
  "Major mode for buffers showing a Khronos Vulkan sample."
  (add-hook 'kill-buffer-hook #'ewv-vulkan--close nil t)
  (add-hook 'change-major-mode-hook #'ewv-vulkan--close nil t))

(defun ewv-vulkan--alive-p (buffer)
  "Non-nil if BUFFER has a native view that is starting or running."
  (when-let* ((id (buffer-local-value 'ewv-vulkan--id buffer)))
    (string-match-p "\\`\\(starting\\|running\\)" (ewv-native-vks-status id))))

;;;###autoload
(defun ewv-vulkan-sample (sample)
  "Run the Khronos Vulkan-Samples SAMPLE in a buffer.
SAMPLE is a sample id such as \"hello_triangle\"; interactively, pick one
from the list.  Build the samples library once first: run
src/vulkan/fetch_deps.ps1 and src/vulkan/build.ps1 in the ewv checkout
\(see src/vulkan/README.md).  One sample runs at a time, so starting
another offers to stop the running one.  Samples that need Vulkan
features this machine lacks say so in their buffer."
  (interactive
   (list (file-name-nondirectory
          (completing-read "Vulkan sample: " (ewv-vulkan--samples) nil t))))
  (unless (file-exists-p ewv-vulkan-library)
    (user-error "%s not found: build it with src/vulkan/build.ps1 (see src/vulkan/README.md)"
                ewv-vulkan-library))
  (let* ((name (format "*ewv-vulkan %s*" sample))
         (buffer (get-buffer name))
         (running (seq-find (lambda (b) (and (not (eq b buffer)) (ewv-vulkan--alive-p b)))
                            ewv-vulkan--buffers)))
    (unless (and buffer (ewv-vulkan--alive-p buffer))
      (when running
        (if (y-or-n-p (format "Stop %s to run %s? "
                              (buffer-local-value 'ewv-vulkan--sample running) sample))
            (kill-buffer running)
          (user-error "One Vulkan sample at a time")))
      (setq buffer (get-buffer-create name))
      (with-current-buffer buffer
        ;; A buffer whose sample stopped (an error, or its window went with a
        ;; frame) gets a fresh view.
        (ewv-vulkan--close)
        (ewv-vulkan-mode)
        (setq ewv-vulkan--sample sample
              ewv-vulkan--frame (selected-frame)
              ewv-vulkan--id (ewv-native-vks-open
                              sample (selected-frame)
                              (expand-file-name ewv-vulkan-library)
                              (expand-file-name ewv-vulkan-samples-root))))
      (unless ewv-vulkan--buffers
        (ewv-vulkan--enable-hooks))
      (push buffer ewv-vulkan--buffers)
      (ewv-vulkan--describe buffer))
    (switch-to-buffer buffer)
    (ewv-vulkan--sync)
    buffer))

(provide 'ewv-vulkan)

;;; ewv-vulkan.el ends here

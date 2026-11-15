;;; winine-vulkan.el --- Khronos Vulkan-Samples in Emacs buffers  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Windows counterpart of appine's `appine-vulkan-sample':
;;
;;   M-x winine-vulkan-sample    pick one of the Khronos Vulkan-Samples
;;                            (https://github.com/KhronosGroup/Vulkan-Samples)
;;                            and run it in a buffer
;;
;; The samples are ewv's separate library, ewv-vulkan-samples.dll, which winine
;; shares with ewv: it is built once in the ewv checkout that holds this
;; winine folder (see ../src/vulkan/README.md):
;;
;;   ..\src\vulkan\fetch_deps.ps1    libraries and assets (about 1.5 GB)
;;   ..\src\vulkan\build.ps1         the library (about 1300 build steps)
;;
;; The view follows its buffer like the Direct3D 12 demos (winine-dx12.el):
;; split, resize, switch away (it stops drawing) and back, move it to another
;; frame; killing the buffer stops the sample.  Left mouse button and drag go
;; to the sample (most samples orbit their camera with it); keys stay with
;; Emacs.  `k' kills the buffer, `s' shows the status, `g' re-syncs the view.
;;
;; One sample runs at a time: the samples' framework keeps global state.  A
;; sample that needs something this GPU or driver lacks (ray tracing,
;; particular extensions) does not start, and the buffer says why.

;;; Code:

(require 'winine-core)

(defgroup winine-vulkan nil
  "Khronos Vulkan-Samples in Emacs buffers, based on winine."
  :group 'winine
  :prefix "winine-vulkan-")

(defcustom winine-vulkan-library
  (expand-file-name "../ewv-vulkan-samples.dll" winine-core--src-dir)
  "Path of ewv-vulkan-samples.dll, built by ewv's src/vulkan/build.ps1."
  :type 'file)

(defcustom winine-vulkan-samples-root
  (expand-file-name "../src/vulkan/Vulkan-Samples" winine-core--src-dir)
  "The Vulkan-Samples folder: samples/ to list, assets/ and shaders/ to run."
  :type 'directory)

(defvar-local winine-vulkan--id nil
  "Id of this buffer's native Vulkan view.")
(defvar-local winine-vulkan--frame nil
  "The frame whose window the native view is currently a child of.")
(defvar-local winine-vulkan--sample nil
  "Id of the sample shown in this buffer, e.g. \"hello_triangle\".")

(defvar winine-vulkan--buffers nil
  "Live buffers that own a native Vulkan view.")

(defun winine-vulkan--samples ()
  "The Khronos Vulkan samples as \"category/id\" strings."
  (let ((root (expand-file-name "samples" winine-vulkan-samples-root)))
    (unless (file-directory-p root)
      (user-error "No Vulkan samples in %s" root))
    (sort (mapcar (lambda (cmake)
                    (file-relative-name (directory-file-name (file-name-directory cmake)) root))
                  (file-expand-wildcards (expand-file-name "*/*/CMakeLists.txt" root)))
          #'string<)))

(defun winine-vulkan--sync (&rest _)
  "Place every sample view over the window showing its buffer.
Views whose buffer is not displayed are hidden (and stop drawing)."
  (dolist (buffer winine-vulkan--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when winine-vulkan--id
          (let ((window (get-buffer-window buffer t)))
            (if (not window)
                (winine-native-vks-set-visible winine-vulkan--id nil)
              (let ((frame (window-frame window)))
                (unless (eq frame winine-vulkan--frame)
                  (winine-native-vks-reparent winine-vulkan--id frame)
                  (setq winine-vulkan--frame frame))
                (winine-native-vks-resize winine-vulkan--id (winine-core--get-window-edges window))
                (winine-native-vks-set-visible winine-vulkan--id t)))))))))

(defun winine-vulkan--delete-frame (frame)
  "Move views off FRAME before it goes: its child windows die with it."
  (when-let* ((other (car (remq frame (frame-list)))))
    (dolist (buffer winine-vulkan--buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and winine-vulkan--id (eq winine-vulkan--frame frame))
            (winine-native-vks-set-visible winine-vulkan--id nil)
            (winine-native-vks-reparent winine-vulkan--id other)
            (setq winine-vulkan--frame other)))))))

(defun winine-vulkan--enable-hooks ()
  (add-hook 'window-configuration-change-hook #'winine-vulkan--sync)
  (add-hook 'window-size-change-functions #'winine-vulkan--sync)
  (add-hook 'delete-frame-functions #'winine-vulkan--delete-frame))

(defun winine-vulkan--disable-hooks ()
  (remove-hook 'window-configuration-change-hook #'winine-vulkan--sync)
  (remove-hook 'window-size-change-functions #'winine-vulkan--sync)
  (remove-hook 'delete-frame-functions #'winine-vulkan--delete-frame))

(defun winine-vulkan--close ()
  "Stop the current buffer's sample and close its view."
  (when winine-vulkan--id
    (winine-native-vks-close winine-vulkan--id)
    (setq winine-vulkan--id nil))
  (setq winine-vulkan--buffers (delq (current-buffer) winine-vulkan--buffers))
  (unless winine-vulkan--buffers
    (winine-vulkan--disable-hooks)))

(defun winine-vulkan--kill-emacs ()
  "Stop every sample before Emacs exits, so none is left mid-frame."
  (dolist (buffer winine-vulkan--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (winine-vulkan--close)))))

(add-hook 'kill-emacs-hook #'winine-vulkan--kill-emacs)

(defun winine-vulkan--describe (buffer)
  "Write the sample's status into BUFFER; it shows when there is no view."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when winine-vulkan--id
        (let ((status (winine-native-vks-status winine-vulkan--id))
              (inhibit-read-only t))
          (erase-buffer)
          (insert "Vulkan sample " winine-vulkan--sample "\n\n" status "\n")
          (if (string-prefix-p "starting" status)
              ;; Still loading shaders and assets: look again shortly.
              (run-with-timer 0.25 nil #'winine-vulkan--describe buffer)
            (when (string-prefix-p "error" status)
              (message "winine-vulkan: %s" status))))))))

(defun winine-vulkan-status ()
  "Show what the current buffer's sample is doing and how many frames it drew."
  (interactive)
  (unless winine-vulkan--id
    (user-error "Not a Vulkan sample buffer"))
  (message "%s (%d frames)"
           (winine-native-vks-status winine-vulkan--id)
           (winine-native-vks-frame-count winine-vulkan--id)))

(defun winine-vulkan-refresh ()
  "Re-sync the native views with their windows."
  (interactive)
  (winine-vulkan--sync))

(defvar winine-vulkan-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'winine-vulkan-refresh)
    (define-key map (kbd "s") #'winine-vulkan-status)
    (define-key map (kbd "k") #'kill-current-buffer)
    map))

(define-derived-mode winine-vulkan-mode special-mode "WININE-Vulkan"
  "Major mode for buffers showing a Khronos Vulkan sample."
  (add-hook 'kill-buffer-hook #'winine-vulkan--close nil t)
  (add-hook 'change-major-mode-hook #'winine-vulkan--close nil t))

(defun winine-vulkan--alive-p (buffer)
  "Non-nil if BUFFER has a native view that is starting or running."
  (when-let* ((id (buffer-local-value 'winine-vulkan--id buffer)))
    (string-match-p "\\`\\(starting\\|running\\)" (winine-native-vks-status id))))

;;;###autoload
(defun winine-vulkan-sample (sample)
  "Run the Khronos Vulkan-Samples SAMPLE in a buffer.
SAMPLE is a sample id such as \"hello_triangle\"; interactively, pick one
from the list.  Build the samples library once first: run
src/vulkan/fetch_deps.ps1 and src/vulkan/build.ps1 in the ewv checkout
that holds winine \(see ../src/vulkan/README.md); winine shares ewv's
library.  One sample runs at a time, so starting
another offers to stop the running one.  Samples that need Vulkan
features this machine lacks say so in their buffer."
  (interactive
   (list (file-name-nondirectory
          (completing-read "Vulkan sample: " (winine-vulkan--samples) nil t))))
  (unless (file-exists-p winine-vulkan-library)
    (user-error "%s not found: build it with ewv's src/vulkan/build.ps1 (see ../src/vulkan/README.md)"
                winine-vulkan-library))
  (let* ((name (format "*winine-vulkan %s*" sample))
         (buffer (get-buffer name))
         (running (seq-find (lambda (b) (and (not (eq b buffer)) (winine-vulkan--alive-p b)))
                            winine-vulkan--buffers)))
    (unless (and buffer (winine-vulkan--alive-p buffer))
      (when running
        (if (y-or-n-p (format "Stop %s to run %s? "
                              (buffer-local-value 'winine-vulkan--sample running) sample))
            (kill-buffer running)
          (user-error "One Vulkan sample at a time")))
      (setq buffer (get-buffer-create name))
      (with-current-buffer buffer
        ;; A buffer whose sample stopped (an error, or its window went with a
        ;; frame) gets a fresh view.
        (winine-vulkan--close)
        (winine-vulkan-mode)
        (setq winine-vulkan--sample sample
              winine-vulkan--frame (selected-frame)
              winine-vulkan--id (winine-native-vks-open
                              sample (selected-frame)
                              (expand-file-name winine-vulkan-library)
                              (expand-file-name winine-vulkan-samples-root))))
      (unless winine-vulkan--buffers
        (winine-vulkan--enable-hooks))
      (push buffer winine-vulkan--buffers)
      (winine-vulkan--describe buffer))
    (switch-to-buffer buffer)
    (winine-vulkan--sync)
    buffer))

(provide 'winine-vulkan)

;;; winine-vulkan.el ends here

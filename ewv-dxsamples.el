;;; ewv-dxsamples.el --- Microsoft DirectX-Graphics-Samples in Emacs buffers  -*- lexical-binding: t; -*-

;;; Commentary:

;; M-x ewv-dxsample     pick one of Microsoft's DirectX-Graphics-Samples
;;                      (https://github.com/microsoft/DirectX-Graphics-Samples:
;;                      the D3D12 samples, MiniEngine, the technique demos)
;;                      and run it in a buffer
;;
;; The samples are vendored in src/dxsamples/DirectX-Graphics-Samples and stay
;; the Win32 programs upstream wrote; ewv starts one, adopts its window into
;; the Emacs frame and keeps it over the buffer's window (src/dxs.rs).  A
;; sample that is not built yet is built first, on request, with
;; src/dxsamples/build.ps1 in a compilation buffer.  Samples that load scenes or
;; textures need src/dxsamples/fetch_assets.ps1 run once (see the README there).
;;
;; The view follows its buffer like the Direct3D 12 demos: split, resize,
;; switch away and back, move it to another frame; killing the buffer closes
;; the sample.  Click the view to give the sample the keyboard (most samples
;; take keys); click any Emacs window to take it back.  Several samples can
;; run at once, each in its own process.  `k' kills the buffer, `s' shows the
;; status, `g' re-syncs the view, `r' restarts the sample.

;;; Code:

(require 'ewv-core)
(require 'cl-lib)
(require 'seq)

(defgroup ewv-dxsamples nil
  "Microsoft DirectX-Graphics-Samples in Emacs buffers, based on ewv."
  :group 'ewv
  :prefix "ewv-dxsamples-")

(defcustom ewv-dxsamples-dir
  (expand-file-name "src/dxsamples" ewv-core--src-dir)
  "The folder holding build.ps1, projects.tsv and DirectX-Graphics-Samples/."
  :type 'directory)

(defcustom ewv-dxsamples-powershell "pwsh"
  "PowerShell used to run build.ps1."
  :type 'string)

(defvar-local ewv-dxsamples--id nil
  "Id of this buffer's native sample view.")
(defvar-local ewv-dxsamples--frame nil
  "The frame whose window the sample's window is currently a child of.")
(defvar-local ewv-dxsamples--sample nil
  "This buffer's sample: (NAME CATEGORY PROJECT EXE), as `ewv-dxsamples--index' has it.")
(defvar-local ewv-dxsamples--timer nil
  "Timer that refreshes this buffer's status text.")

(defvar ewv-dxsamples--buffers nil
  "Live buffers that own a native sample view.")

;;; The sample list

(defun ewv-dxsamples--root ()
  (expand-file-name "DirectX-Graphics-Samples" ewv-dxsamples-dir))

(defun ewv-dxsamples--index ()
  "Samples from projects.tsv, as (NAME CATEGORY PROJECT EXE) with absolute paths."
  (let ((file (expand-file-name "projects.tsv" ewv-dxsamples-dir))
        (root (ewv-dxsamples--root))
        samples)
    (unless (file-exists-p file)
      (user-error "No %s: run build.ps1 -Index there" file))
    (with-temp-buffer
      (insert-file-contents file)
      (dolist (line (split-string (buffer-string) "\n" t))
        (unless (string-prefix-p "#" line)
          (pcase-let ((`(,name ,category ,project ,exe) (split-string (string-trim-right line) "\t")))
            (push (list name category (expand-file-name project root) (expand-file-name exe root))
                  samples)))))
    (nreverse samples)))

(defun ewv-dxsamples--label (sample)
  (format "%s/%s" (nth 1 sample) (nth 0 sample)))

(defun ewv-dxsamples--read (prompt)
  "Read a sample with completion; built ones are marked."
  (let* ((samples (ewv-dxsamples--index))
         (table (mapcar (lambda (s) (cons (ewv-dxsamples--label s) s)) samples))
         (completion-extra-properties
          (list :annotation-function
                (lambda (label)
                  (let ((s (cdr (assoc label table))))
                    (if (and s (file-exists-p (nth 3 s))) "  built" "  (not built)"))))))
    (cdr (assoc (completing-read prompt table nil t) table))))

;;; Building

(defun ewv-dxsamples--build-command (&rest args)
  (mapconcat #'shell-quote-argument
             (append (list ewv-dxsamples-powershell "-NoProfile" "-ExecutionPolicy" "Bypass" "-File"
                           (expand-file-name "build.ps1" ewv-dxsamples-dir))
                     args)
             " "))

(defun ewv-dxsamples-build (sample &optional then)
  "Build SAMPLE with build.ps1 in a compilation buffer.
With THEN, a function, call it with no arguments when the build succeeds."
  (interactive (list (ewv-dxsamples--read "Build DirectX sample: ")))
  (let* ((default-directory (file-name-as-directory ewv-dxsamples-dir))
         (buffer (compilation-start (ewv-dxsamples--build-command (car sample))
                                    'compilation-mode
                                    (lambda (_) (format "*ewv-dxsamples build %s*" (car sample))))))
    (when then
      (with-current-buffer buffer
        (add-hook 'compilation-finish-functions
                  (lambda (_buffer status)
                    (when (string-prefix-p "finished" status)
                      (funcall then)))
                  nil t)))
    buffer))

;;; Views

(defun ewv-dxsamples--sync (&rest _)
  "Place every sample view over the window showing its buffer; hide the others."
  (dolist (buffer ewv-dxsamples--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when ewv-dxsamples--id
          (let ((window (get-buffer-window buffer t)))
            (if (not window)
                (ewv-native-dxs-set-visible ewv-dxsamples--id nil)
              (let ((frame (window-frame window)))
                (unless (eq frame ewv-dxsamples--frame)
                  (ewv-native-dxs-reparent ewv-dxsamples--id frame)
                  (setq ewv-dxsamples--frame frame))
                (ewv-native-dxs-resize ewv-dxsamples--id (ewv-core--get-window-edges window))
                (ewv-native-dxs-set-visible ewv-dxsamples--id t)))))))))

(defun ewv-dxsamples--delete-frame (frame)
  "Move views off FRAME before it goes: its child windows die with it."
  (when-let* ((other (car (remq frame (frame-list)))))
    (dolist (buffer ewv-dxsamples--buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and ewv-dxsamples--id (eq ewv-dxsamples--frame frame))
            (ewv-native-dxs-set-visible ewv-dxsamples--id nil)
            (ewv-native-dxs-reparent ewv-dxsamples--id other)
            (setq ewv-dxsamples--frame other)))))))

(defun ewv-dxsamples--enable-hooks ()
  (add-hook 'window-configuration-change-hook #'ewv-dxsamples--sync)
  (add-hook 'window-size-change-functions #'ewv-dxsamples--sync)
  (add-hook 'delete-frame-functions #'ewv-dxsamples--delete-frame))

(defun ewv-dxsamples--disable-hooks ()
  (remove-hook 'window-configuration-change-hook #'ewv-dxsamples--sync)
  (remove-hook 'window-size-change-functions #'ewv-dxsamples--sync)
  (remove-hook 'delete-frame-functions #'ewv-dxsamples--delete-frame))

(defun ewv-dxsamples--close ()
  "Close the current buffer's sample."
  (when ewv-dxsamples--timer
    (cancel-timer ewv-dxsamples--timer)
    (setq ewv-dxsamples--timer nil))
  (when ewv-dxsamples--id
    (ewv-native-dxs-close ewv-dxsamples--id)
    (setq ewv-dxsamples--id nil))
  (setq ewv-dxsamples--buffers (delq (current-buffer) ewv-dxsamples--buffers))
  (unless ewv-dxsamples--buffers
    (ewv-dxsamples--disable-hooks)))

(defun ewv-dxsamples--kill-emacs ()
  "Close every sample before Emacs exits."
  (dolist (buffer ewv-dxsamples--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ewv-dxsamples--close)))))

(add-hook 'kill-emacs-hook #'ewv-dxsamples--kill-emacs)

(defun ewv-dxsamples--describe (buffer)
  "Write the sample's status into BUFFER (it shows when there is no view)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when ewv-dxsamples--id
        (let ((status (ewv-native-dxs-status ewv-dxsamples--id))
              (inhibit-read-only t))
          (erase-buffer)
          (insert "DirectX sample " (ewv-dxsamples--label ewv-dxsamples--sample) "\n\n"
                  status "\n\n"
                  (abbreviate-file-name (nth 3 ewv-dxsamples--sample)) "\n")
          (when (string-match-p "\\`\\(error\\|exited\\)" status)
            (insert "\nr restarts it.  Samples that load scenes or textures need\n"
                    (abbreviate-file-name (expand-file-name "fetch_assets.ps1" ewv-dxsamples-dir))
                    " run once.\n")
            (when ewv-dxsamples--timer
              (cancel-timer ewv-dxsamples--timer)
              (setq ewv-dxsamples--timer nil))
            (when (string-prefix-p "error" status)
              (message "ewv-dxsamples: %s" status))))))))

(defun ewv-dxsamples-status ()
  "Show what the current buffer's sample is doing."
  (interactive)
  (unless ewv-dxsamples--id
    (user-error "No sample is running in this buffer"))
  (message "%s" (ewv-native-dxs-status ewv-dxsamples--id)))

(defun ewv-dxsamples-refresh ()
  "Re-sync the sample views with their windows."
  (interactive)
  (ewv-dxsamples--sync))

(defun ewv-dxsamples-restart ()
  "Close this buffer's sample and start it again."
  (interactive)
  (let ((sample ewv-dxsamples--sample))
    (unless sample
      (user-error "Not a DirectX sample buffer"))
    (ewv-dxsamples--close)
    (ewv-dxsamples--start (current-buffer) sample)))

(defvar ewv-dxsamples-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'ewv-dxsamples-refresh)
    (define-key map (kbd "s") #'ewv-dxsamples-status)
    (define-key map (kbd "r") #'ewv-dxsamples-restart)
    (define-key map (kbd "k") #'kill-current-buffer)
    map))

(define-derived-mode ewv-dxsamples-mode special-mode "EWV-DXSample"
  "Major mode for buffers showing a DirectX-Graphics-Samples program."
  (add-hook 'kill-buffer-hook #'ewv-dxsamples--close nil t)
  (add-hook 'change-major-mode-hook #'ewv-dxsamples--close nil t))

(defun ewv-dxsamples--alive-p (buffer)
  (when-let* ((id (buffer-local-value 'ewv-dxsamples--id buffer)))
    (string-match-p "\\`\\(starting\\|running\\)" (ewv-native-dxs-status id))))

(defun ewv-dxsamples--start (buffer sample)
  "Start SAMPLE's program in BUFFER (in `ewv-dxsamples-mode')."
  (with-current-buffer buffer
    (unless (derived-mode-p 'ewv-dxsamples-mode)
      (ewv-dxsamples-mode))
    (let ((exe (nth 3 sample)))
      (setq ewv-dxsamples--sample sample
            ewv-dxsamples--frame (selected-frame)
            ewv-dxsamples--id (ewv-native-dxs-open exe "" (file-name-directory exe) (selected-frame))))
    (unless ewv-dxsamples--buffers
      (ewv-dxsamples--enable-hooks))
    (cl-pushnew buffer ewv-dxsamples--buffers)
    ;; Until it runs, and then now and again: it may exit by itself.
    (setq ewv-dxsamples--timer
          (run-with-timer 0.25 1 #'ewv-dxsamples--describe buffer))
    (ewv-dxsamples--describe buffer))
  (when (get-buffer-window buffer t)
    (ewv-dxsamples--sync)))

;;;###autoload
(defun ewv-dxsample (sample)
  "Run SAMPLE, one of Microsoft's DirectX-Graphics-Samples, in a buffer.
Interactively, pick one; a sample not built yet is built first (after
asking) with src/dxsamples/build.ps1.  SAMPLE is (NAME CATEGORY PROJECT
EXE) as `ewv-dxsamples--index' returns, or a sample NAME such as
\"D3D12HelloTriangle\"."
  (interactive (list (ewv-dxsamples--read "DirectX sample: ")))
  (when (stringp sample)
    (setq sample (or (assoc sample (ewv-dxsamples--index))
                     (user-error "No DirectX sample named %s" sample))))
  (if (not (file-exists-p (nth 3 sample)))
      (if (y-or-n-p (format "%s is not built yet.  Build it now (then run it)? " (car sample)))
          (ewv-dxsamples-build sample (lambda () (ewv-dxsample sample)))
        (user-error "Build it with %s %s" (expand-file-name "build.ps1" ewv-dxsamples-dir) (car sample)))
    (let* ((name (format "*ewv-dxsample %s*" (car sample)))
           (buffer (get-buffer name)))
      (unless (and buffer (ewv-dxsamples--alive-p buffer))
        (setq buffer (get-buffer-create name))
        (with-current-buffer buffer
          (ewv-dxsamples--close))
        (ewv-dxsamples--start buffer sample))
      (switch-to-buffer buffer)
      (ewv-dxsamples--sync)
      buffer)))

(provide 'ewv-dxsamples)

;;; ewv-dxsamples.el ends here

;;; winine-dxsamples.el --- Microsoft DirectX-Graphics-Samples in Emacs buffers  -*- lexical-binding: t; -*-

;;; Commentary:

;; M-x winine-dxsample     pick one of Microsoft's DirectX-Graphics-Samples
;;                      (https://github.com/microsoft/DirectX-Graphics-Samples:
;;                      the D3D12 samples, MiniEngine, the technique demos)
;;                      and run it in a buffer
;;
;; The samples are vendored in ewv's src/dxsamples/DirectX-Graphics-Samples (one
;; folder up from winine, shared with ewv) and stay
;; the Win32 programs upstream wrote; winine starts one, adopts its window into
;; the Emacs frame and keeps it over the buffer's window (src/dxs.cpp).  A
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

(require 'winine-core)
(require 'cl-lib)
(require 'seq)

(defgroup winine-dxsamples nil
  "Microsoft DirectX-Graphics-Samples in Emacs buffers, based on winine."
  :group 'winine
  :prefix "winine-dxsamples-")

(defcustom winine-dxsamples-dir
  (expand-file-name "../src/dxsamples" winine-core--src-dir)
  "The folder holding build.ps1, projects.tsv and DirectX-Graphics-Samples/."
  :type 'directory)

(defcustom winine-dxsamples-powershell "pwsh"
  "PowerShell used to run build.ps1."
  :type 'string)

(defvar-local winine-dxsamples--id nil
  "Id of this buffer's native sample view.")
(defvar-local winine-dxsamples--frame nil
  "The frame whose window the sample's window is currently a child of.")
(defvar-local winine-dxsamples--sample nil
  "This buffer's sample: (NAME CATEGORY PROJECT EXE), as `winine-dxsamples--index' has it.")
(defvar-local winine-dxsamples--timer nil
  "Timer that refreshes this buffer's status text.")

(defvar winine-dxsamples--buffers nil
  "Live buffers that own a native sample view.")

;;; The sample list

(defun winine-dxsamples--root ()
  (expand-file-name "DirectX-Graphics-Samples" winine-dxsamples-dir))

(defun winine-dxsamples--index ()
  "Samples from projects.tsv, as (NAME CATEGORY PROJECT EXE) with absolute paths."
  (let ((file (expand-file-name "projects.tsv" winine-dxsamples-dir))
        (root (winine-dxsamples--root))
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

(defun winine-dxsamples--label (sample)
  (format "%s/%s" (nth 1 sample) (nth 0 sample)))

(defun winine-dxsamples--read (prompt)
  "Read a sample with completion; built ones are marked."
  (let* ((samples (winine-dxsamples--index))
         (table (mapcar (lambda (s) (cons (winine-dxsamples--label s) s)) samples))
         (completion-extra-properties
          (list :annotation-function
                (lambda (label)
                  (let ((s (cdr (assoc label table))))
                    (if (and s (file-exists-p (nth 3 s))) "  built" "  (not built)"))))))
    (cdr (assoc (completing-read prompt table nil t) table))))

;;; Building

(defun winine-dxsamples--build-command (&rest args)
  (mapconcat #'shell-quote-argument
             (append (list winine-dxsamples-powershell "-NoProfile" "-ExecutionPolicy" "Bypass" "-File"
                           (expand-file-name "build.ps1" winine-dxsamples-dir))
                     args)
             " "))

(defun winine-dxsamples-build (sample &optional then)
  "Build SAMPLE with build.ps1 in a compilation buffer.
With THEN, a function, call it with no arguments when the build succeeds."
  (interactive (list (winine-dxsamples--read "Build DirectX sample: ")))
  (let* ((default-directory (file-name-as-directory winine-dxsamples-dir))
         (buffer (compilation-start (winine-dxsamples--build-command (car sample))
                                    'compilation-mode
                                    (lambda (_) (format "*winine-dxsamples build %s*" (car sample))))))
    (when then
      (with-current-buffer buffer
        (add-hook 'compilation-finish-functions
                  (lambda (_buffer status)
                    (when (string-prefix-p "finished" status)
                      (funcall then)))
                  nil t)))
    buffer))

;;; Views

(defun winine-dxsamples--sync (&rest _)
  "Place every sample view over the window showing its buffer; hide the others."
  (dolist (buffer winine-dxsamples--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when winine-dxsamples--id
          (let ((window (get-buffer-window buffer t)))
            (if (not window)
                (winine-native-dxs-set-visible winine-dxsamples--id nil)
              (let ((frame (window-frame window)))
                (unless (eq frame winine-dxsamples--frame)
                  (winine-native-dxs-reparent winine-dxsamples--id frame)
                  (setq winine-dxsamples--frame frame))
                (winine-native-dxs-resize winine-dxsamples--id (winine-core--get-window-edges window))
                (winine-native-dxs-set-visible winine-dxsamples--id t)))))))))

(defun winine-dxsamples--delete-frame (frame)
  "Move views off FRAME before it goes: its child windows die with it."
  (when-let* ((other (car (remq frame (frame-list)))))
    (dolist (buffer winine-dxsamples--buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and winine-dxsamples--id (eq winine-dxsamples--frame frame))
            (winine-native-dxs-set-visible winine-dxsamples--id nil)
            (winine-native-dxs-reparent winine-dxsamples--id other)
            (setq winine-dxsamples--frame other)))))))

(defun winine-dxsamples--enable-hooks ()
  (add-hook 'window-configuration-change-hook #'winine-dxsamples--sync)
  (add-hook 'window-size-change-functions #'winine-dxsamples--sync)
  (add-hook 'delete-frame-functions #'winine-dxsamples--delete-frame))

(defun winine-dxsamples--disable-hooks ()
  (remove-hook 'window-configuration-change-hook #'winine-dxsamples--sync)
  (remove-hook 'window-size-change-functions #'winine-dxsamples--sync)
  (remove-hook 'delete-frame-functions #'winine-dxsamples--delete-frame))

(defun winine-dxsamples--close ()
  "Close the current buffer's sample."
  (when winine-dxsamples--timer
    (cancel-timer winine-dxsamples--timer)
    (setq winine-dxsamples--timer nil))
  (when winine-dxsamples--id
    (winine-native-dxs-close winine-dxsamples--id)
    (setq winine-dxsamples--id nil))
  (setq winine-dxsamples--buffers (delq (current-buffer) winine-dxsamples--buffers))
  (unless winine-dxsamples--buffers
    (winine-dxsamples--disable-hooks)))

(defun winine-dxsamples--kill-emacs ()
  "Close every sample before Emacs exits."
  (dolist (buffer winine-dxsamples--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (winine-dxsamples--close)))))

(add-hook 'kill-emacs-hook #'winine-dxsamples--kill-emacs)

(defun winine-dxsamples--describe (buffer)
  "Write the sample's status into BUFFER (it shows when there is no view)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when winine-dxsamples--id
        (let ((status (winine-native-dxs-status winine-dxsamples--id))
              (inhibit-read-only t))
          (erase-buffer)
          (insert "DirectX sample " (winine-dxsamples--label winine-dxsamples--sample) "\n\n"
                  status "\n\n"
                  (abbreviate-file-name (nth 3 winine-dxsamples--sample)) "\n")
          (when (string-match-p "\\`\\(error\\|exited\\)" status)
            (insert "\nr restarts it.  Samples that load scenes or textures need\n"
                    (abbreviate-file-name (expand-file-name "fetch_assets.ps1" winine-dxsamples-dir))
                    " run once.\n")
            (when winine-dxsamples--timer
              (cancel-timer winine-dxsamples--timer)
              (setq winine-dxsamples--timer nil))
            (when (string-prefix-p "error" status)
              (message "winine-dxsamples: %s" status))))))))

(defun winine-dxsamples-status ()
  "Show what the current buffer's sample is doing."
  (interactive)
  (unless winine-dxsamples--id
    (user-error "No sample is running in this buffer"))
  (message "%s" (winine-native-dxs-status winine-dxsamples--id)))

(defun winine-dxsamples-refresh ()
  "Re-sync the sample views with their windows."
  (interactive)
  (winine-dxsamples--sync))

(defun winine-dxsamples-restart ()
  "Close this buffer's sample and start it again."
  (interactive)
  (let ((sample winine-dxsamples--sample))
    (unless sample
      (user-error "Not a DirectX sample buffer"))
    (winine-dxsamples--close)
    (winine-dxsamples--start (current-buffer) sample)))

(defvar winine-dxsamples-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'winine-dxsamples-refresh)
    (define-key map (kbd "s") #'winine-dxsamples-status)
    (define-key map (kbd "r") #'winine-dxsamples-restart)
    (define-key map (kbd "k") #'kill-current-buffer)
    map))

(define-derived-mode winine-dxsamples-mode special-mode "WININE-DXSample"
  "Major mode for buffers showing a DirectX-Graphics-Samples program."
  (add-hook 'kill-buffer-hook #'winine-dxsamples--close nil t)
  (add-hook 'change-major-mode-hook #'winine-dxsamples--close nil t))

(defun winine-dxsamples--alive-p (buffer)
  (when-let* ((id (buffer-local-value 'winine-dxsamples--id buffer)))
    (string-match-p "\\`\\(starting\\|running\\)" (winine-native-dxs-status id))))

(defun winine-dxsamples--start (buffer sample)
  "Start SAMPLE's program in BUFFER (in `winine-dxsamples-mode')."
  (with-current-buffer buffer
    (unless (derived-mode-p 'winine-dxsamples-mode)
      (winine-dxsamples-mode))
    (let ((exe (nth 3 sample)))
      (setq winine-dxsamples--sample sample
            winine-dxsamples--frame (selected-frame)
            winine-dxsamples--id (winine-native-dxs-open exe "" (file-name-directory exe) (selected-frame))))
    (unless winine-dxsamples--buffers
      (winine-dxsamples--enable-hooks))
    (cl-pushnew buffer winine-dxsamples--buffers)
    ;; Until it runs, and then now and again: it may exit by itself.
    (setq winine-dxsamples--timer
          (run-with-timer 0.25 1 #'winine-dxsamples--describe buffer))
    (winine-dxsamples--describe buffer))
  (when (get-buffer-window buffer t)
    (winine-dxsamples--sync)))

;;;###autoload
(defun winine-dxsample (sample)
  "Run SAMPLE, one of Microsoft's DirectX-Graphics-Samples, in a buffer.
Interactively, pick one; a sample not built yet is built first (after
asking) with src/dxsamples/build.ps1.  SAMPLE is (NAME CATEGORY PROJECT
EXE) as `winine-dxsamples--index' returns, or a sample NAME such as
\"D3D12HelloTriangle\"."
  (interactive (list (winine-dxsamples--read "DirectX sample: ")))
  (when (stringp sample)
    (setq sample (or (assoc sample (winine-dxsamples--index))
                     (user-error "No DirectX sample named %s" sample))))
  (if (not (file-exists-p (nth 3 sample)))
      (if (y-or-n-p (format "%s is not built yet.  Build it now (then run it)? " (car sample)))
          (winine-dxsamples-build sample (lambda () (winine-dxsample sample)))
        (user-error "Build it with %s %s" (expand-file-name "build.ps1" winine-dxsamples-dir) (car sample)))
    (let* ((name (format "*winine-dxsample %s*" (car sample)))
           (buffer (get-buffer name)))
      (unless (and buffer (winine-dxsamples--alive-p buffer))
        (setq buffer (get-buffer-create name))
        (with-current-buffer buffer
          (winine-dxsamples--close))
        (winine-dxsamples--start buffer sample))
      (switch-to-buffer buffer)
      (winine-dxsamples--sync)
      buffer)))

(provide 'winine-dxsamples)

;;; winine-dxsamples.el ends here

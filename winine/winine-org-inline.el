;; -*- lexical-binding: t; -*-

(require 'org)
(defvar-local winine-show-links nil)
(defvar-local winine-scroll-hook-running nil)
(org-add-link-type "winine")

(defun winine-get-img-bounds()
  (let (bounds
        cinfo

        (wind-bounds (window-body-pixel-edges))
        left top right bottom
        )
    ;; (setq cinfo (cl-coerce (cl-subseq (window-cursor-info) 1 5) 'list))
    (setq cinfo (posn-x-y (posn-at-point)))
    (setq cinfo (flatten-list (list (posn-x-y (posn-at-point))
                                    (posn-object-width-height (posn-at-point)))))

    (setq left (+ (nth 0 cinfo) (nth 0 wind-bounds)))
    (setq top (+ (nth 1 cinfo) (nth 1 wind-bounds)))
    (setq right (min (+  (nth 2 cinfo) left) (nth 2 wind-bounds)))
    (setq bottom (min (+ (nth 3 cinfo) top) (nth 3 wind-bounds)))
    (setq bounds (list left top right bottom))
    (posn-x-y (posn-at-point))
    (posn-object-width-height (posn-at-point))
    (posn-at-point)
    bounds
    )
  )

;;; 使用这个来跟踪一个 image 来显示 webview
(defun winine-window-scroll-hook (window start)
  ;; (run-with-timer 0.001 nil (lambda ()
                              (save-excursion
                                (with-selected-window window
                                  (with-current-buffer (window-buffer window)
                                    (unless winine-scroll-hook-running
                                      (setq winine-scroll-hook-running t)
                                      (goto-char (point-min))
                                      (let (pt
                                            rt
                                            winine-id
                                            bounds
                                            begin
                                            end
                                            (win-start (window-start window))
                                            (win-end (window-end window t)))
                                        (while (setq pt (text-property-search-forward 'winine-id))
                                          ;; (message "%S" (list :pt pt :point (point) :win-start win-start :win-end win-end))
                                          (setq begin (prop-match-beginning pt))
                                          (setq end (prop-match-end pt))
                                          (setq winine-id (prop-match-value pt))
                                          (if (and (>= begin win-start) (<= end win-end))
                                              (save-excursion
                                                (goto-char (prop-match-beginning pt))
                                                (sit-for 0.01)
                                                (push (list :cursor-info (window-cursor-info) :winine-id (prop-match-value pt) :point (point)) rt)
                                                (setq bounds (winine-get-img-bounds))
                                                (winine-native-webview-resize winine-id bounds)
                                                (winine-native-webview-set-visible winine-id t)
                                                )
                                            (winine-native-webview-set-visible winine-id nil)
                                            )
                                          )
                                        rt
                                        )
                                      (setq winine-scroll-hook-running nil)
                                      )
                                    ))
                                )
                              ;; ))
  )

(defun winine-parse-org-links (link)
  (let* ((begin (org-element-begin link))
         (end (org-element-end link))
         (data (read (org-element-property :path link)))
         (width (plist-get data :width))
         (height (plist-get data :height))
         (url (plist-get data :url))
         (svg (svg-create width height))
         winine-wv
         img
         bounds
         )
    (svg-rectangle svg 0 0 "100%" "100%" :fill-color "transparent" :stroke-width 0 :stroke-color "transparent")
    ;; (svg-rectangle svg 0 0 "100%" "100%" :fill-color "green")
    ;; (svg-rectangle svg 0 0 "100%" "100%" :fill-color "white")
    (setq img (svg-image svg))
    (list begin end data)
    (org-with-silent-modifications
     (put-text-property begin end 'display img)
     )
    (unless (get-text-property begin 'winine-id)
      (save-excursion (goto-char begin)
                      (sit-for 0.001)
                      (setq bounds (winine-get-img-bounds))
                      (setq winine-wv (winine-native-webview-new (winine-get-frame-hwnd) bounds))
                      (winine-native-webview-load-sync winine-wv url)
                      ;; (winine-native-webview-resize winine-wv width height)
                      (org-with-silent-modifications
                       (put-text-property begin end 'winine-id winine-wv)
                       (put-text-property begin end 'winine-bounds bounds)
                       )
                      )
      )
    (setq winine-wv (get-text-property begin 'winine-id))
    (save-excursion (goto-char begin)
                    (sit-for 0.001)
                    (setq bounds (winine-get-img-bounds))
                    (winine-native-webview-resize winine-wv bounds)
                    )

    ))

;; (defun test-winine-links()
;;   (with-current-buffer "test.org"
;;     (with-selected-window (get-buffer-window (current-buffer))
;;       (org-element-map (org-element-parse-buffer) 'link
;;         #'winine-parse-org-links
;;         )
;;       ))
;;   )
(defun test-winine-links()
  (interactive)
  (setq-local winine-show-links t)
  ;; (remove-hook 'window-scroll-functions #'winine-window-scroll-hook)

  (org-element-map (org-element-parse-buffer) 'link
    #'winine-parse-org-links
    )
  )

(add-hook 'window-scroll-functions #'winine-window-scroll-hook)
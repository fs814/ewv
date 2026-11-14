;; -*- lexical-binding: t; -*-

;;; rust debug env setup
;; does not work on Windows for dynamic module
;; (setenv "RUST_BACKTRACE" "1")
;; (setenv "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS" "--proxy-server=http://127.0.0.1:7887")
;; use set command
;; set RUST_BACKTRACE=1
;; set WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--proxy-server=127.0.0.1:7897"

;; cargo build --lib && emacs  --debug-init -Q -L . -l ewv.el

(require 'cl-lib)


(defgroup ewv nil
  "Emacs Webview2"
  :link '(info-link :tag "Info Manual" "(ewv)")
  :link '(url-link :tag "Website" "https://github.com/heartnheart/ewv")
  :group 'tools
  :prefix "ewv-")


(require 'ewv-browser)

;; Direct3D 12 demos: M-x ewv-dx12-triangle, M-x ewv-dx12-raytracing
(require 'ewv-dx12)

;; RSS reader: M-x ewv-rss
(require 'ewv-rss)

;; Link hints and the selection assistant in every browser tab
(require 'ewv-plugins)

;; (require 'ewv-mode-line)

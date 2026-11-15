;; -*- lexical-binding: t; -*-

;;; winine: ewv with its native module written in C++ (README.md here).
;; Everything ewv has, under the winine- prefix: M-x winine-browser-open-url,
;; the DX12 demos, the Vulkan samples, the RSS reader and the page plugins.
;;
;; Proxy: WebView2 reads WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS from the
;; environment Emacs was started with (setenv has no effect on the module):
;;   set WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--proxy-server=127.0.0.1:7897"
;;
;; Settings\winbuild\editor\emacsplugin\ewv\build_ewv.ps1 && emacs --debug-init -Q -L . -l winine.el

(require 'cl-lib)


(defgroup winine nil
  "Emacs Webview2"
  :link '(info-link :tag "Info Manual" "(winine)")
  :link '(url-link :tag "Website" "https://github.com/heartnheart/ewv")
  :group 'tools
  :prefix "winine-")


(require 'winine-browser)

;; Direct3D 12 demos: M-x winine-dx12-triangle, M-x winine-dx12-raytracing
(require 'winine-dx12)

;; Khronos Vulkan-Samples: M-x winine-vulkan-sample (ewv's ../src/vulkan/README.md)
(require 'winine-vulkan)

;; Microsoft DirectX-Graphics-Samples: M-x winine-dxsample (ewv's ../src/dxsamples/README.md)
(require 'winine-dxsamples)

;; RSS reader: M-x winine-rss
(require 'winine-rss)

;; Link hints and the selection assistant in every browser tab
(require 'winine-plugins)

;; (require 'winine-mode-line)

;; ewv gets this feature from its Rust module (#[emacs::module(name="ewv")]);
;; winine's module provides winine-native instead, so say it here.
(provide 'winine)

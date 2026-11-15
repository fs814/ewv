;; -*- lexical-binding: t; -*-

(setq debug-on-error t)
(add-to-list 'load-path (file-name-directory (or load-file-name (buffer-file-name))))
(setq winine-browser-user-data-folder (expand-file-name "myuserdir" invocation-directory))

(require 'winine)
;; https://github.com/prem-k-r/MaterialYouNewTab
(setq winine-browser-default-url "extension://jjpokbgpiljgndebfoljdeihhkpcpfgl/index.html")

(setq winine-browser-default-url "https://www.baidu.com")


(add-hook 'emacs-startup-hook #'winine-browser-reopen-all-pinned-tabs)
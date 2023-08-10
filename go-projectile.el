;;; go-projectile.el --- Go add-ons for Projectile

;; Copyright (C) 2014 Doug MacEachern

;; Author: Doug MacEachern <dougm@vmware.com>
;; URL: https://github.com/dougm/go-projectile
;; Keywords: project, convenience
;; Version: 0.2.1
;; Package-Requires: ((projectile "0.10.0") (go-mode "0") (go-eldoc "0.16") (go-rename "0") (go-guru "0") (dash "2.17.0"))

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;; This library provides some Go functionality to Projectile.

;; To use this library, put this file in your Emacs load path, and
;; call (require 'go-projectile)

;;; Code:

(require 'projectile)
(require 'go-eldoc)
(require 'go-guru)
(require 'go-rename)
(require 'vc-git)
(require 'autorevert)
(require 'dash)

(defcustom go-projectile-switch-gopath 'always
  "Specify whether GOPATH should be updated when switching projects.
Choices are 'always, 'maybe to update only if buffer is not in the
current GOPATH, or 'never to leave GOPATH untouched."
  :type '(choice (const always)
                 (const maybe)
                 (const never))
  :group 'projectile)

(defvar go-projectile-files-ignore
  '("third_party" "vendor")
  "A list of regular expressions to ignore in `go-projectile-current-project-files'.")

(defvar go-projectile-tools-path (expand-file-name (concat user-emacs-directory "/gotools"))
  "GOPATH for Go tools used by Emacs.")

(defvar go-projectile-url-file "go-projectile-url.eld"
  "File containing project import URL.")

(defvar go-projectile-tools
  '((gocode    . "github.com/mdempsky/gocode")
    (golint    . "golang.org/x/lint/golint")
    (godef     . "github.com/rogpeppe/godef")
    (errcheck  . "github.com/kisielk/errcheck")
    (godoc     . "golang.org/x/tools/cmd/godoc")
    (gogetdoc  . "github.com/zmb3/gogetdoc")
    (goimports . "golang.org/x/tools/cmd/goimports")
    (gorename  . "golang.org/x/tools/cmd/gorename")
    (gomvpkg   . "golang.org/x/tools/cmd/gomvpkg")
    (guru      . "golang.org/x/tools/cmd/guru"))
  "Import paths for Go tools.")

(defun go-projectile-tools-add-path ()
  "Add go-projectile-tools-path to `exec-path' and friends."
  (let ((path (concat go-projectile-tools-path "/bin")))
    (unless (member path exec-path)
      (add-to-list 'exec-path path)
      (setenv "PATH" (concat (getenv "PATH") path-separator path))
      (setq go-guru-command (concat path "/guru"))
      (setq go-rename-command (concat path "/gorename"))
      (let ((gogetdoc (executable-find "gogetdoc")))
        (when gogetdoc
          (setq godoc-at-point-function #'godoc-gogetdoc
                godoc-use-completing-read t))))))

(defun go-projectile-get-tools (&optional flag)
  "Install go related tools via go get.  Optional FLAG to update."
  (or go-projectile-tools-path (error "Error: go-projectile-tools-path not set"))
  (go-projectile-tools-add-path)
  (let ((env (getenv "GOPATH")))
    (setenv "GOPATH" go-projectile-tools-path)
    (dolist (tool go-projectile-tools)
      (let* ((url (cdr tool))
             (cmd (concat "go install " (if flag (concat flag " ")) url "@latest"))
             (result (shell-command-to-string cmd)))
        (message "Go tool %s: %s" (car tool) cmd)
        (unless (string= "" result)
          (error result))))
    (setenv "GOPATH" env)))

(defun go-projectile-install-tools ()
  "Install go related tools."
  (interactive)
  (go-projectile-get-tools))

(defun go-projectile-update-tools ()
  "Update go related tools."
  (interactive)
  (go-projectile-get-tools))

(defun go-projectile-current-project-files ()
  "Return a list of .go files for the current project."
  (-filter (lambda (file)
             (and (string= (file-name-extension file) "go")
                  (not (-any? (lambda (pat)
                                (string-match pat file))
                              go-projectile-files-ignore))))
           (projectile-current-project-files)))

(defun go-projectile-make-gopath ()
  "A project's Makefile may provide a `gopath' target for use by `go-projectile-set-gopath'."
  (let* ((buf (or buffer-file-name default-directory))
         (mkfile (locate-dominating-file buf "Makefile")))
    (when mkfile
      (let ((dir (expand-file-name (file-name-directory mkfile))))
        (with-temp-buffer
          (when (zerop (call-process "make" nil (current-buffer) nil "-s" "-C" dir "gopath"))
            (let ((path (buffer-string)))
              (unless (string= path "")
                path))))))))

(defun go-projectile-derive-gopath (&optional path)
  "Attempt to derive GOPATH for the current buffer.
PATH defaults to GOPATH via getenv, used to determine if buffer is in current GOPATH already."
  (let* ((path (or path (getenv "GOPATH")))
         (buf (or buffer-file-name default-directory))
         (dir (locate-dominating-file buf "src")))
    (if dir
        (let ((rel (file-relative-name buf dir)))
          (if (and path (locate-file rel (split-string path path-separator t)))
              path
            (directory-file-name (expand-file-name dir)))))))

(defun go-projectile-directory-gopath-p ()
  "Check if `default-directory' is under the current GOPATH."
  (car (mapcar (lambda (p)
                 (string-prefix-p p default-directory))
               (split-string (or (getenv "GOPATH") "") path-separator t))))

(defvar-local go-projectile-project-gopath nil)

(defun go-projectile-set-gopath ()
  "Attempt to setenv GOPATH for the current project."
  (interactive)
  (let ((path (or go-projectile-project-gopath
                  (go-projectile-make-gopath)
                  (go-projectile-derive-gopath))))
    (when path
      (message "setenv GOPATH=%s" path)
      (setq go-projectile-project-gopath path)
      (setenv "GOPATH" path))))

(defun go-projectile-git-grep ()
  "Run `vc-git-grep' on *.go in the $GOPATH/src/ directory of the current buffer."
  (interactive)
  (let ((src (concat (locate-dominating-file (or buffer-file-name default-directory) "src") "src"))
        (regexp (if (and transient-mark-mode mark-active)
                    (buffer-substring (region-beginning) (region-end))
                  (read-string (projectile-prepend-project-name "Grep for: ")
                               (projectile-symbol-at-point)))))
    (vc-git-grep regexp "*.go" src)))

(defun go-projectile-set-local-keys ()
  "Set local Projectile key bindings for Go projects."
  (define-key projectile-command-map (kbd "W") 'go-projectile-rewrite)
  (define-key projectile-command-map (kbd "w") 'go-rename)
  (define-key projectile-command-map (kbd "N") 'go-projectile-get)
  (define-key projectile-command-map (kbd "G") 'go-projectile-git-grep))

(defun go-projectile-mode ()
  "Hook for `go-mode-hook' to set Go projectile related key bindings."
  (require 'go-guru)
  (go-projectile-set-local-keys))

(defun go-projectile-switch-project ()
  "Hook for `projectile-after-switch-project-hook' to set GOPATH."
  ;; (projectile-project-type) could be 'go or 'make
  ;; we just check if there are any *.go files in the project, unless the `projectile-project-type' local is set.
  (when (or (eq projectile-project-type 'go)
            (funcall projectile-go-project-test-function))
    (unless (eq go-projectile-switch-gopath 'never)
      (if (eq go-projectile-switch-gopath 'always)
          (setenv "GOPATH" nil))
      (go-projectile-set-gopath))))

(defun go-projectile-switch-project-window ()
  "Hook for `buffer-list-update-hook' to set GOPATH.
When `projectile-project-type' set to `go', GOPATH is checked, calling `go-projectile-switch-project' if needed."
  (if (and (eq projectile-project-type 'go)
           (null (active-minibuffer-window)))
      (let* ((index 5)
             (frame (backtrace-frame index))
             (found 0))
        (while (not (equal found 2))
          (setq frame (backtrace-frame (incf index)))
          (when (equal t (first frame))
            (incf found)))
        (let ((caller (second frame)))
          (if (and (eq caller 'select-window)
                   (not (go-projectile-directory-gopath-p)))
              (go-projectile-switch-project))))))

(defun go-projectile-rewrite-pattern-args (n)
  "Generate function call pattern with N arguments for `go-projectile-rewrite-pattern'."
  (let ((arg (string-to-char "a")))
    (mapconcat 'identity
               (mapcar (lambda (i)
                         (char-to-string (+ arg i)))
                       (number-sequence 0 (- n 1))) ",")))

(defun go-projectile-rewrite-pattern ()
  "Generate default pattern for `go-projectile-rewrite'."
  (let ((fn (go-eldoc--get-funcinfo)))
    (if (and fn (> (plist-get fn :index) 0))
        (let* ((name (plist-get fn :name))
               (signature (go-eldoc--analyze-signature (plist-get fn :signature)))
               (args (go-eldoc--split-types-string (plist-get signature :arg-type))))
          (format "x.%s(%s)" name (go-projectile-rewrite-pattern-args (length args))))
      (projectile-symbol-at-point))))

(defun go-projectile-rewrite (from to)
  "Apply Go rewrite rule to current project via gofmt -r 'FROM -> TO'."
  (interactive
   (let ((pat (read-string (projectile-prepend-project-name "Pattern: ")
                           (go-projectile-rewrite-pattern))))
     (list pat (read-string (projectile-prepend-project-name "Replacement: ") pat))))
  (projectile-with-default-dir (projectile-project-root)
    (projectile-save-project-buffers)
    (apply 'call-process "gofmt" nil (get-buffer-create "*Go Rewrite*") nil
           "-l" "-w" "-r" (format "%s -> %s" from to)
           (go-projectile-current-project-files))
    (auto-revert-buffers)))

(defun go-projectile-import-url (path)
  "Remove scheme from PATH if needed, to make go get happy."
  (let ((url (url-generic-parse-url path)))
    (if (eq nil (url-type url))
        path
      (concat (url-host url) (car (url-path-and-query url))))))

(defun go-projectile-get (url dir)
  "Create a new project via 'go get' and switch to the project.
URL should be a valid import path, example: github.com/coreos/etcd
DIR is the directory to use for GOPATH when running go get."
  (interactive
   (let ((repo (read-string "URL: ")))
     (list repo (ido-read-directory-name "Directory: " "~/"))))
  (let* ((name (file-name-base url))
         (default-directory (concat (expand-file-name dir) name))
         (url (go-projectile-import-url url)))
    (if (file-exists-p default-directory)
        (error "%s already exists" default-directory))
    (make-directory default-directory t)
    (setenv "GOPATH" default-directory)
    (let ((result (shell-command-to-string (concat "go get " url))))
      (unless (string= "" result)
        (error result)))
    (projectile-serialize url go-projectile-url-file)
    (let* ((path (concat default-directory "/src/" url))
           (project (projectile-root-bottom-up path)))
      (projectile-add-known-project project)
      (projectile-switch-project-by-name project))))

(defun go-projectile-update ()
  "Update the current project via 'go get -u'."
  (interactive)
  (let* ((buf (or buffer-file-name default-directory))
         (default-directory (or (locate-dominating-file buf go-projectile-url-file)
                                (error "Unable to find project URL")))
         (url (projectile-unserialize go-projectile-url-file)))
    (async-shell-command (concat "go get -u -v " url))))

(add-hook 'projectile-after-switch-project-hook 'go-projectile-switch-project)
(eval-after-load 'go-mode
  '(add-hook 'go-mode-hook 'go-projectile-mode))

(provide 'go-projectile)
;;; go-projectile.el ends here

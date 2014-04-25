;;; go-projectile.el --- Go add-ons for Projectile

;; Copyright (C) 2014 Doug MacEachern

;; Author: Doug MacEachern
;; Created: 2014-04-24
;; Keywords: project, convenience
;; Version: 0.1.0
;; Package-Requires: ((projectile "0.10.0") (go-mode "0") (go-eldoc "0"))

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

(defcustom go-projectile-switch-gopath 'always
  "Specify whether GOPATH should be updated when switching projects.
Choices are 'always, 'maybe to update only if buffer is not in the
current GOPATH, or 'never to leave GOPATH untouched."
  :type '(choice (const always)
		 (const maybe)
		 (const never))
  :group 'projectile)

(defvar go-project-files-ignore
  '("third_party")
  "A list of regular expressions to ignore in `go-projectile-current-project-files'.")

(defun go-projectile-current-project-files ()
  "Return a list of .go files for the current project."
  (-filter (lambda (file)
             (and (string= (file-name-extension file) "go")
                  (not (-any? (lambda (pat)
                                (string-match pat file))
                              go-project-files-ignore))))
           (projectile-current-project-files)))

(defun go-projectile-make-gopath ()
  "A project's Makefile may provide a `gopath' target for use by `go-projectile-set-gopath'."
  (let* ((buf (or buffer-file-name default-directory))
         (mkfile (locate-dominating-file buf "Makefile")))
    (when mkfile
      (let ((dir (expand-file-name (file-name-directory mkfile))))
        (with-temp-buffer
          (when (zerop (call-process "make" nil (current-buffer) nil "-C" dir "gopath"))
            (buffer-string)))))))

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

(defun go-projectile-set-gopath ()
  "Attempt to setenv GOPATH for the current project."
  (interactive)
  (let ((path (or (go-projectile-make-gopath)
                  (go-projectile-derive-gopath))))
    (when path
      (message "setenv GOPATH=%s" path)
      (setenv "GOPATH" path))))

(defun go-projectile-set-local-keys ()
  "Set local Projectile key bindings for Go projects."
  (dolist (map '(("W" go-projectile-rewrite)
                 ("N" go-projectile-get)))
    (local-set-key (kbd (concat projectile-keymap-prefix " " (car map))) (nth 1 map))))

(defun go-projectile-mode ()
  "Hook for `projectile-mode-hook' to set Go related key bindings."
  (when (funcall projectile-go-function)
    (go-projectile-set-local-keys)))

(defun go-projectile-switch-project ()
  "Hook for `projectile-switch-project-hook' to set GOPATH."
  ;; projectile-project-type could be 'go or 'make
  ;; we just check if there are any *.go files in the project.
  (when (funcall projectile-go-function)
    (unless (eq go-projectile-switch-gopath 'never)
      (if (eq go-projectile-switch-gopath 'always)
         (setenv "GOPATH" nil))
      (go-projectile-set-gopath))))

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
    (if fn
        (let* ((name (plist-get fn :name))
               (signature (go-eldoc--analyze-signature (plist-get fn :signature)))
               (args (go-eldoc--split-argument-type (plist-get signature :arg-type))))
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
    (setenv "GOPATH" default-directory)
    (let ((result (shell-command-to-string (concat "go get " url))))
      (unless (string= "" result)
        (error result)))
    (let* ((path (concat default-directory "/src/" url))
           (project (projectile-root-bottom-up path)))
      (projectile-add-known-project project)
      (projectile-switch-project-by-name project))))

(add-hook 'projectile-switch-project-hook 'go-projectile-switch-project)
(add-hook 'projectile-mode-hook 'go-projectile-mode)

(provide 'go-projectile)
;;; go-projectile.el ends here

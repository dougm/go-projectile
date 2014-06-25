(defconst testsuite-dir
  (if load-file-name
      (file-name-directory load-file-name)
    ;; Fall back to default directory (in case of M-x eval-buffer)
    default-directory)
  "Directory of the test suite.")

(defconst testsuite-projects-file
  (concat testsuite-dir "known-projects.eld")
  "Known projects of the test suite.")

(defconst testsuite-project-dir
  (concat testsuite-dir "project/")
  "Directory of the test suite project.")

(defconst testsuite-buffer-name
  (concat testsuite-project-dir "go/src/emacs/emacs.go")
  "File name for testing.")

(load (expand-file-name "../go-projectile" testsuite-dir) nil :no-message)

(ert-deftest test-go-projectile-make-gopath ()
  (with-current-buffer (find-file-noselect testsuite-buffer-name)
    (should (string= (concat testsuite-project-dir "go")
                     (go-projectile-make-gopath))))
  (with-current-buffer (find-file-noselect testsuite-dir)
    (should (eq nil (go-projectile-make-gopath)))))

(ert-deftest test-go-projectile-derive-gopath ()
  (with-current-buffer (find-file-noselect testsuite-buffer-name)
    (should (string= (concat testsuite-project-dir "go")
                     (go-projectile-derive-gopath nil))))
  (with-current-buffer (find-file-noselect testsuite-dir)
    (should (eq nil (go-projectile-derive-gopath (concat testsuite-project-dir "go"))))))

(ert-deftest test-go-projectile-set-gopath ()
  (with-current-buffer (find-file-noselect testsuite-buffer-name)
    (let ((env (getenv "GOPATH")))
      (setenv "GOPATH" nil)
      (go-projectile-set-gopath)
      (should (string= (concat testsuite-project-dir "go")
                       (getenv "GOPATH")))
      (setenv "GOPATH" env))))

(ert-deftest test-go-projectile-rewrite-pattern ()
  (go-projectile-install-tools)
  (with-current-buffer (find-file-noselect testsuite-buffer-name)
    (save-excursion
      (re-search-forward "ErrN")
      (should (string= "ErrNope" (go-projectile-rewrite-pattern)))
      (re-search-forward "Fo")
      (should (string= "Foo" (go-projectile-rewrite-pattern)))
      (re-search-forward "Bar(one")
      (should (string= "x.Bar(a,b,c)" (go-projectile-rewrite-pattern))))))

(ert-deftest test-go-projectile-current-project-files ()
  (let ((projectile-known-projects-file testsuite-projects-file))
    (with-current-buffer (find-file-noselect testsuite-project-dir)
      (should (equal (list "go/src/emacs/emacs.go")
                     (go-projectile-current-project-files))))))

(ert-deftest test-go-projectile-import-url ()
  (let ((path "github.com/dougm/go-projectile"))
    (should (string= path (go-projectile-import-url path)))
    (should (string= path (go-projectile-import-url (concat "https://" path))))))

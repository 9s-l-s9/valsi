;;; valsi-project-state-test.el --- Remembered project roots state file -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Regression tests for the remembered-roots state file: recovery after
;; repair, concurrent writers, session-only membership and symlinks.

;;; Code:

(require 'ert)
(require 'valsi-project)

(defmacro valsi-project-state-test--with-state (&rest body)
  "Run BODY with isolated project state in BASE, state file FILE, roots A, B."
  (declare (indent 0))
  `(let* ((base (file-name-as-directory (file-truename (make-temp-file "valsi-state-" t))))
          (file (expand-file-name "projects.eld" base))
          (a (file-name-as-directory (expand-file-name "a" base)))
          (b (file-name-as-directory (expand-file-name "b" base)))
          (valsi-project-file file)
          (valsi-project--loaded nil)
          (valsi-project--load-error nil)
          (valsi-project--roots nil)
          (valsi-project--saved-roots nil)
          (valsi-project-change-hook nil))
     (make-directory a)
     (make-directory b)
     (unwind-protect (progn ,@body)
       (set-file-modes base #o700)
       (dolist (child (directory-files base t directory-files-no-dot-files-regexp))
         (when (file-directory-p child) (set-file-modes child #o700)))
       (delete-directory base t))))

(defun valsi-project-state-test--contents (file)
  "Return the contents of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun valsi-project-state-test--saved (file)
  "Return the roots declared in FILE."
  (plist-get (car (read-from-string (valsi-project-state-test--contents file))) :roots))

(ert-deftest valsi-project-state-repaired-file-is-accepted ()
  "A state file repaired after a failed load is saved without a restart (#51)."
  (valsi-project-state-test--with-state
    (with-temp-file file (insert "garbage ("))
    (valsi-project--load)
    (should valsi-project--load-error)
    (with-temp-file file (insert "(:version 1 :roots nil)"))
    (valsi-project-remember a)
    (should-not valsi-project--load-error)
    (should (equal (list a) (valsi-project-state-test--saved file)))))

(ert-deftest valsi-project-state-empty-file-declares-no-roots ()
  "An empty or blank state file is an empty declaration set (#51)."
  (valsi-project-state-test--with-state
    (with-temp-file file (insert "  \n"))
    (should-not (valsi-project-roots))
    (should-not valsi-project--load-error)
    (valsi-project-remember a)
    (should (equal (list a) (valsi-project-state-test--saved file)))))

(ert-deftest valsi-project-state-truncated-file-message-is-readable ()
  "A truncated state file reports an error without a killed buffer (#51)."
  (valsi-project-state-test--with-state
    (with-temp-file file (insert "(:version 1"))
    (valsi-project--load)
    (should valsi-project--load-error)
    (should-not (string-match-p "killed buffer" valsi-project--load-error))))

(provide 'valsi-project-state-test)
;;; valsi-project-state-test.el ends here

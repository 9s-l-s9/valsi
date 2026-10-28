;;; valsi-lint.el --- Fatal Checkdoc gate for `make lint' -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `checkdoc-file' only prints warnings in batch mode and the process still
;; exits 0.  This driver collects every diagnostic and exits non-zero when
;; any file has one, so `make check' actually enforces Checkdoc.

;;; Code:

(require 'cl-lib)
(require 'checkdoc)

(defun valsi-lint-checkdoc-file (file)
  "Run Checkdoc on FILE and return its diagnostic messages, oldest first.
The diagnostics are still reported as warnings, as `checkdoc-file' does."
  (let ((messages nil)
        (report (symbol-function 'checkdoc-error))
        (live (find-buffer-visiting file)))
    (cl-letf (((symbol-function 'checkdoc-error)
               (lambda (point msg)
                 (push msg messages)
                 (funcall report point msg))))
      (unwind-protect (checkdoc-file file)
        (let ((buffer (find-buffer-visiting file)))
          (when (and buffer (not live)) (kill-buffer buffer)))))
    (nreverse messages)))

(defun valsi-lint-batch-checkdoc ()
  "Checkdoc the files left on the command line; exit 1 on any diagnostic."
  (let ((failed 0))
    (dolist (file command-line-args-left)
      (cl-incf failed (length (valsi-lint-checkdoc-file file))))
    (setq command-line-args-left nil)
    (unless (zerop failed)
      (message "valsi-lint: %d Checkdoc diagnostic(s)" failed)
      (kill-emacs 1))))

(provide 'valsi-lint)
;;; valsi-lint.el ends here

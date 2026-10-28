;;; valsi-lint-test.el --- Tests for the Checkdoc gate -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Regression tests for issue #21: `make lint' must fail on Checkdoc
;; diagnostics instead of only printing them.

;;; Code:

(require 'ert)
(require 'valsi-lint)

(defun valsi-lint-test--write (file body)
  "Write a minimal library around BODY to FILE."
  (let ((name (file-name-nondirectory file)))
    (with-temp-file file
      (insert ";;; " name " --- Sample -*- lexical-binding: t; -*-\n\n"
              ";;; Commentary:\n\n;; Sample.\n\n;;; Code:\n\n"
              body
              "\n\n(provide '" (file-name-sans-extension name) ")\n"
              ";;; " name " ends here\n"))))

(defun valsi-lint-test--diagnostics (body)
  "Return Checkdoc diagnostics for a temporary library containing BODY."
  (let* ((dir (make-temp-file "valsi-lint-test" t))
         (file (expand-file-name "valsi-lint-sample.el" dir)))
    (unwind-protect
        (progn
          (valsi-lint-test--write file body)
          (let ((warning-minimum-log-level :emergency)
                (inhibit-message t))
            (valsi-lint-checkdoc-file file)))
      (delete-directory dir t))))

(ert-deftest valsi-lint-test-reports-bad-docstring ()
  "A docstring Checkdoc rejects yields diagnostics."
  (should (valsi-lint-test--diagnostics
           "(defun valsi-lint-sample (x)\n  \"no capital and no period\"\n  x)")))

(ert-deftest valsi-lint-test-accepts-clean-file ()
  "A Checkdoc-clean library yields no diagnostics."
  (should-not (valsi-lint-test--diagnostics
               "(defun valsi-lint-sample (x)\n  \"Return X.\"\n  x)")))

(ert-deftest valsi-lint-test-batch-exits-non-zero ()
  "The batch driver exits non-zero only when a file has diagnostics."
  (let* ((dir (make-temp-file "valsi-lint-test" t))
         (bad (expand-file-name "valsi-lint-bad.el" dir))
         (good (expand-file-name "valsi-lint-good.el" dir))
         (lint (locate-library "valsi-lint.el" t))
         (emacs (expand-file-name invocation-name invocation-directory)))
    (unwind-protect
        (progn
          (valsi-lint-test--write
           bad "(defun valsi-lint-bad (x)\n  \"no period\"\n  x)")
          (valsi-lint-test--write
           good "(defun valsi-lint-good (x)\n  \"Return X.\"\n  x)")
          (should (zerop (call-process emacs nil nil nil "-Q" "--batch"
                                       "-l" lint "-f" "valsi-lint-batch-checkdoc"
                                       good)))
          (should-not (zerop (call-process emacs nil nil nil "-Q" "--batch"
                                           "-l" lint
                                           "-f" "valsi-lint-batch-checkdoc"
                                           bad))))
      (delete-directory dir t))))

(provide 'valsi-lint-test)
;;; valsi-lint-test.el ends here

;;; valsi-parse-test.el --- ERT tests for the shared recognizers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Regression tests for the shared pure-elisp recognizer helpers in
;; `valsi-parse' and the graph edges built on them.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-parse)
(require 'valsi-graph)

;;;; Requirements traces (#7)

(ert-deftest valsi-parse-test-requirements-underscore-ids ()
  "Requirement ids containing an underscore are not truncated."
  (should (equal '("1.1" "FR_2")
                 (valsi-parse-requirements "_Requirements: 1.1, FR_2_")))
  (should (equal '("REQ_1_2")
                 (valsi-parse-requirements "  - _Requirements: REQ_1_2_.")))
  (should (equal '("1.1" "2.1")
                 (valsi-parse-requirements "  _Requirements: 1.1, 2.1_")))
  (let ((f (make-temp-file "valsi-parse-test" nil ".md"
                           "- [ ] 1 a\n  - _Requirements: FR_2, 1.1_\n")))
    (unwind-protect
        (should (member (list (file-name-nondirectory f) "trace" "FR_2, 1.1")
                        (valsi-graph--edges-plan f)))
      (delete-file f))))

(provide 'valsi-parse-test)
;;; valsi-parse-test.el ends here

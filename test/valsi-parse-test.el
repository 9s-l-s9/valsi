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

;;;; Leading tags (#8)

(ert-deftest valsi-parse-test-tags-leading-only ()
  "Only the leading run of bracketed tokens is read as tags."
  (should (null (valsi-parse-tags "Implement parser, see [RFC1]")))
  (should (null (valsi-parse-tags "Fix the [P] thing see [docs](x) and [foo]")))
  (should (null (valsi-parse-tags "T002 Initialize [language] project")))
  (should (null (valsi-parse-tags "[docs](x) explain")))
  (should (equal '(("P" . parallel) ("US1" . story))
                 (valsi-parse-tags "T001 [P] [US1] do [later]")))
  (should (equal '(("P" . parallel) ("US1" . story))
                 (valsi-parse-tags "[P] [US1] do")))
  (should (equal '(("P" . parallel) ("US3" . story))
                 (valsi-parse-tags "T301 [P] US3 react setup")))
  (should (equal '(("wip" . label))
                 (valsi-parse-tags "1.2 [wip] Set up see [RFC1]"))))

(provide 'valsi-parse-test)
;;; valsi-parse-test.el ends here

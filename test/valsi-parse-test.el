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
(require 'valsi-plan)
(require 'valsi-decision)
(require 'valsi-overview)
(require 'valsi-registry)

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

(ert-deftest valsi-parse-test-requirements-highlight-underscore-ids ()
  "The plan highlight covers the whole trace, as `valsi-parse-req-re' does."
  (with-temp-buffer
    (insert "- [ ] 1 a\n  - _Requirements: FR_2, REQ_1_2_.\n")
    (setq-local font-lock-defaults '(nil t))
    (setq-local font-lock-keywords nil)
    (font-lock-add-keywords nil valsi-plan-font-lock-keywords)
    (font-lock-ensure)
    (goto-char (point-min))
    (let* ((beg (search-forward "_Requirements:"))
           (close (1- (search-forward "REQ_1_2_"))))
      (dolist (pos (list (- beg 14) (- close 2) close))
        (should (eq (get-text-property pos 'face) 'valsi-trace-face)))
      ;; The trailing delimiter consumed by the regexp is not highlighted.
      (should-not (get-text-property (1+ close) 'face)))))

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

;;;; ATX headings (#10)

(ert-deftest valsi-parse-test-heading-commonmark ()
  "Headings take at most six hashes and drop a closing hash sequence."
  (should (null (valsi-parse-heading "####### x")))
  (should (equal '(6 . "x") (valsi-parse-heading "###### x")))
  (should (equal '(2 . "Foo") (valsi-parse-heading "## Foo ##")))
  (should (equal '(2 . "Foo") (valsi-parse-heading "## Foo #####   ")))
  (should (equal '(2 . "Foo#") (valsi-parse-heading "## Foo#")))
  (should (equal '(1 . "C# notes") (valsi-parse-heading "# C# notes")))
  (should (equal '(2 . "") (valsi-parse-heading "## ##"))))

;;;; Code fences (#18)

(ert-deftest valsi-parse-test-lines-skip-fences ()
  "Fenced lines are omitted by default and marked with KEEP-FENCED."
  (with-temp-buffer
    (insert "a\n```elisp\n- [ ] x\n```\nb\n~~~~\n```\n~~~\n~~~~\nc\n``` x`y\nd\n")
    (should (equal '("a" "b" "c" "``` x`y" "d")
                   (mapcar #'valsi-line-text (valsi-parse-lines))))
    (let ((all (valsi-parse-lines nil t)))
      (should (= 12 (length all)))
      (should (equal '(1 2 3 5 6 7 8)
                     (mapcar #'valsi-line-n
                             (cl-remove-if-not #'valsi-line-fenced all)))))))

(ert-deftest valsi-parse-test-fences-plan-and-decision ()
  "Checkboxes and headings inside fences are not tasks, groups or sections."
  (let ((root (valsi-plan-parse "```\n- [ ] x\n# h\n```\n")))
    (should (null (valsi-node-of-type root 'task)))
    (should (null (valsi-node-of-type root 'group))))
  (let ((root (valsi-plan-parse "# Plan\n- [ ] T001 a\n  ```\n  - [ ] T002 b\n  ```\n- [ ] T003 c\n")))
    (should (equal '("T001" "T003")
                   (mapcar (lambda (tk) (valsi-node-prop tk :id))
                           (valsi-node-of-type root 'task)))))
  (let ((root (valsi-decision-parse
               "# ADR\n\n## Context\n\n```md\n## Status\n\nRejected\n```\n\n## Status\n\nAccepted\n")))
    (should (equal "Accepted" (valsi-node-prop root :status)))
    (should (equal '("Context" "Status")
                   (mapcar (lambda (s) (valsi-node-prop s :title))
                           (valsi-node-of-type root 'section)))))
  (let ((root (valsi-registry--parse-generic "# A\n```\n# not\n```\n## B\n")))
    (should (equal '("A" "B")
                   (mapcar (lambda (h) (valsi-node-prop h :title))
                           (valsi-node-of-type root 'heading)))))
  ;; the overview still records the code block itself
  (let ((root (valsi-overview-parse "# A\n```sh\n# not\n```\n")))
    (should (= 1 (length (valsi-node-of-type root 'codeblock))))
    (should (= 1 (length (valsi-node-of-type root 'section))))))

(provide 'valsi-parse-test)
;;; valsi-parse-test.el ends here

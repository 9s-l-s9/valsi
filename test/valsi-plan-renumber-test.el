;;; valsi-plan-renumber-test.el --- ERT tests for plan renumbering -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Regression tests for `valsi-plan-renumber': only task ids and their
;; `depends on' references are rewritten, never prose or code fences.

;;; Code:

(require 'ert)
(require 'valsi-plan)

(ert-deftest valsi-plan-renumber-test-skips-fences-and-prose ()
  "Ids inside code fences and free prose are left untouched.
A dotted sub-id on a task line still follows its parent (#31)."
  (with-temp-buffer
    (insert "# Plan\n"
            "See T005 and T009 for context.\n"
            "- [ ] T005 a\n"
            "- [ ] T009 b, follows T005 (depends on T005)\n"
            "- [ ] T009.1 sub (depends on T009)\n"
            "```\nT009 stays?\n- [ ] T005 fenced\n```\n")
    (valsi-plan-renumber)
    (should (equal (buffer-string)
                   (concat "# Plan\n"
                           "See T005 and T009 for context.\n"
                           "- [ ] T001 a\n"
                           "- [ ] T002 b, follows T005 (depends on T001)\n"
                           "- [ ] T002.1 sub (depends on T002)\n"
                           "```\nT009 stays?\n- [ ] T005 fenced\n```\n")))))

(ert-deftest valsi-plan-renumber-test-reference-count ()
  "The message counts only the rewritten ids and references."
  (with-temp-buffer
    (insert "- [ ] T005 a\n- [ ] T009 b (depends on T005)\n```\nT009 stays?\n```\n")
    (should (equal "valsi-plan-renumber: 2 task(s), 3 reference(s) rewritten"
                   (valsi-plan-renumber)))
    (should (string-match-p "^T009 stays\\?$" (buffer-string)))))

(provide 'valsi-plan-renumber-test)
;;; valsi-plan-renumber-test.el ends here

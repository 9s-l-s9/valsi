;;; valsi-plan-commands-test.el --- ERT regressions for plan commands -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Regression tests for plan editing and query commands, one per fixed
;; issue.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-plan)

(ert-deftest valsi-plan-commands-test-plain-dialect ()
  "A plain task list is not speckit, so inserting mints no Tnnn id (#11)."
  (should (eq 'plain (valsi-node-prop (valsi-plan-parse "- [ ] foo\n- [ ] bar\n")
                                      :dialect)))
  (with-temp-buffer
    (insert "- [ ] foo\n")
    (goto-char (point-min))
    (valsi-plan-insert-task "x")
    (should (equal "- [ ] foo\n- [ ] x\n" (buffer-string)))))

(ert-deftest valsi-plan-commands-test-move-at-eof ()
  "Moving the last task of a file without a final newline keeps lines apart (#12)."
  (with-temp-buffer
    (insert "- [ ] a\n- [ ] b")
    (valsi-plan-move-task-up)
    (should (equal "- [ ] b\n- [ ] a" (buffer-string))))
  (with-temp-buffer
    (insert "- [ ] a\n- [ ] b")
    (goto-char (point-min))
    (valsi-plan-move-task-down)
    (should (equal "- [ ] b\n- [ ] a" (buffer-string)))))

(ert-deftest valsi-plan-commands-test-demote-keeps-tags ()
  "Demote keeps leading tags and strips dotted and `)' ids (#13)."
  (dolist (case '(("- [ ] [P] T005 foo\n" . "- [P] foo\n")
                  ("- [ ] T001.2 foo\n" . "- foo\n")
                  ("- [ ] 1.2) foo\n" . "- foo\n")
                  ("- [ ] [US1] bar\n" . "- [US1] bar\n")))
    (with-temp-buffer
      (insert (car case))
      (goto-char (point-min))
      (valsi-plan-demote-task)
      (should (equal (cdr case) (buffer-string))))))

(provide 'valsi-plan-commands-test)
;;; valsi-plan-commands-test.el ends here

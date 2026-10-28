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

(ert-deftest valsi-plan-commands-test-occur-unknown ()
  "Occur on the `unknown' state lists only unrecognized checkboxes (#19)."
  (let (pattern)
    (with-temp-buffer
      (insert "- [x] a\n- [ ] b\n- [?] c\n")
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "unknown"))
                ((symbol-function 'occur) (lambda (re &rest _) (setq pattern re))))
        (valsi-plan-occur-state))
      (goto-char (point-min))
      (should (equal '("- [?] c")
                     (cl-loop while (re-search-forward pattern nil t)
                              collect (buffer-substring
                                       (line-beginning-position)
                                       (line-end-position))))))))

(ert-deftest valsi-plan-commands-test-toggle-interior ()
  "Toggle changes only the parent's checkbox, as documented (#20)."
  (should-not (string-match-p "offer" (documentation 'valsi-plan-toggle)))
  (with-temp-buffer
    (insert "- [ ] T001 p\n  - [ ] T001.1 c\n")
    (goto-char (point-min))
    (valsi-plan-toggle)
    (should (equal "- [-] T001 p\n  - [ ] T001.1 c\n" (buffer-string)))))

(ert-deftest valsi-plan-commands-test-block-checks-task-first ()
  "Block refuses a non-task line before prompting for a reason (#20)."
  (with-temp-buffer
    (insert "# Plan\n- [ ] T001 a\n")
    (goto-char (point-min))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (error "Prompted"))))
      (should-error (valsi-plan-block) :type 'user-error))))

(provide 'valsi-plan-commands-test)
;;; valsi-plan-commands-test.el ends here

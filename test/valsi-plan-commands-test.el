;;; valsi-plan-commands-test.el --- ERT regressions for plan commands -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Regression tests for plan editing and query commands, one per fixed
;; issue.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-plan)
(require 'valsi-plan-agent)

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

(ert-deftest valsi-plan-commands-test-cancelled-excluded ()
  "Cancelled leaves leave progress and interior state alone (#32)."
  (should (equal '(1 2 0) (valsi-plan--leaf-stats
                           (valsi-plan-parse "- [x] A\n- [c] B\n- [ ] C\n"))))
  (let ((root (valsi-plan-parse
               "- [x] T001 P\n  - [x] T001.1 a\n  - [c] T001.2 b\n")))
    (should (eq 'done (valsi-plan-effective-state
                       (car (valsi-node-of-type root 'task)))))
    (should-not (valsi-plan--lint-issues root))))

(ert-deftest valsi-plan-commands-test-pathref-skips-urls-globs ()
  "URLs and globs in backticks are not treated as manifest files (#33)."
  (let* ((root (valsi-plan-parse
                (concat "- [x] T001 see `https://example.com/foo`, `src/*.el`"
                        " and `nope/missing.el:12`\n")))
         (task (car (valsi-node-of-type root 'task))))
    (should (equal '("T001: done but manifest file missing: nope/missing.el")
                   (mapcar #'cdr (valsi-plan--missing-file-findings
                                  root temporary-file-directory))))
    (should (equal '("nope/missing.el") (valsi-plan--task-files task)))))

(ert-deftest valsi-plan-commands-test-insert-split-after-subtree ()
  "Insert and split on a parent place the new task after its subtree (#34)."
  (with-temp-buffer
    (insert "- [ ] T001 a\n  - [ ] T001.1 b\n- [ ] T002 c\n")
    (goto-char (point-min))
    (valsi-plan-insert-task "new")
    (should (equal (concat "- [ ] T001 a\n  - [ ] T001.1 b\n"
                           "- [ ] T003 new\n- [ ] T002 c\n")
                   (buffer-string))))
  (with-temp-buffer
    (insert "- [ ] T001 a b\n  - [ ] T001.1 c")
    (goto-char (point-min))
    (search-forward "a ")
    (valsi-plan-split-task)
    (should (equal "- [ ] T001 a \n  - [ ] T001.1 c\n- [ ] T002 b"
                   (buffer-string)))))

(ert-deftest valsi-plan-commands-test-bundle-own-context ()
  "An interior task's bundle excludes its children's context (#35)."
  (let* ((root (valsi-plan-parse
                (concat "- [ ] T001 Parent `src/a.el`\n"
                        "  **Verify:** `make parent`\n"
                        "  - parent step\n"
                        "  - [ ] T001.1 Child `src/b.el`\n"
                        "    **Verify:** `make child`\n"
                        "    **Files:** `src/c.el`\n"
                        "    - child step\n")))
         (bundle (valsi-plan-context-bundle
                  root (car (valsi-node-of-type root 'task)))))
    (should (equal '("src/a.el") (plist-get bundle :files)))
    (should-not (string-match-p "make child" (plist-get bundle :verify)))
    (should (string-match-p "make parent" (plist-get bundle :verify)))
    (should (equal '("parent step") (plist-get bundle :steps)))
    (should (equal "Parent `src/a.el`" (plist-get bundle :desc)))
    (should (string-prefix-p "Implement task T001: Parent"
                             (valsi-plan-bundle->prompt bundle)))))

(defun valsi-plan-commands-test--actionable (content)
  "Return the id of the next actionable task in CONTENT."
  (with-temp-buffer
    (insert content)
    (cl-letf (((symbol-function 'valsi-tree)
               (lambda () (valsi-plan-parse (buffer-string)))))
      (let ((task (valsi-plan-next-actionable)))
        (and task (valsi-node-prop task :id))))))

(ert-deftest valsi-plan-commands-test-actionable-skips-interior ()
  "Next-actionable picks open leaves by effective state, never containers (#36)."
  (should (equal "T002" (valsi-plan-commands-test--actionable
                         (concat "- [ ] T001 parent\n"
                                 "  - [ ] T001.1 child (depends on T002)\n"
                                 "- [ ] T002 x\n"))))
  ;; T002's box is open but its children make it effectively done.
  (should (equal "T003" (valsi-plan-commands-test--actionable
                         (concat "- [ ] T001 a (depends on T003)\n"
                                 "- [ ] T002 b\n"
                                 "  - [x] T002.1 sub\n"
                                 "- [ ] T003 c\n"))))
  (should-not (valsi-plan-commands-test--actionable
               (concat "- [ ] T001 a (depends on T002)\n"
                       "- [ ] T002 b\n"
                       "  - [x] T002.1 sub\n"
                       "  - [ ] T002.2 sub (depends on T001)\n"))))

(provide 'valsi-plan-commands-test)
;;; valsi-plan-commands-test.el ends here

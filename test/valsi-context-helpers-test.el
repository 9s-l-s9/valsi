;;; valsi-context-helpers-test.el --- Context ownership tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Check the boundaries of task context, independently of agent execution.

;;; Code:

(require 'ert)
(require 'valsi-plan-agent)

(ert-deftest valsi-context-helpers-task-ownership ()
  "Parent, child and sibling tasks keep their own steps and Verify fields."
  (let* ((root (valsi-plan-parse
                (concat "- [ ] T001 Ungrouped\n"
                        "## Phase 1\n"
                        "- [ ] T002 Parent\n"
                        "  - parent step\n"
                        "  **Verify:** `parent-one`\n"
                        "  **Verify:** `parent-two`\n"
                        "  - [ ] T002.1 Child\n"
                        "    - child step\n"
                        "    **Verify:** `child`\n"
                        "### Detail\n"
                        "- [ ] T003 Sibling\n"
                        "## Phase 2\n"
                        "- [ ] T004 Later\n")))
         (tasks (valsi-node-of-type root 'task))
         (parent (nth 1 tasks))
         (child (nth 2 tasks)))
    (should (equal '(nil "Phase 1" "Phase 1" "Detail" "Phase 2")
                   (mapcar (lambda (task) (valsi-plan--task-group-title root task)) tasks)))
    (should (equal '("parent step")
                   (mapcar (lambda (node) (valsi-node-prop node :text))
                           (valsi-plan--own-nodes parent 'step))))
    (should (equal '("child step")
                   (mapcar (lambda (node) (valsi-node-prop node :text))
                           (valsi-plan--own-nodes child 'step))))
    (should (= 2 (length (valsi-plan--own-nodes parent 'meta))))
    (should (equal "`parent-one`\n`parent-two`" (valsi-plan--task-verify parent)))
    (should (equal "`child`" (valsi-plan--task-verify child)))
    (should (equal "" (valsi-plan--task-verify (nth 3 tasks))))))

(ert-deftest valsi-context-helpers-meta-body ()
  "Metadata strips its recognized label and preserves the actual command."
  (dolist (case '(("  **Verify:**  `make check`  " . "`make check`")
                  ("**Files:** `src/a.el`" . "`src/a.el`")
                  ("  plain text  " . "plain text")
                  ("**Verify:**" . "")
                  ("" . "")))
    (should (equal (cdr case) (valsi-plan--meta-body (car case))))))

(provide 'valsi-context-helpers-test)
;;; valsi-context-helpers-test.el ends here

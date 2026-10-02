;;; valsi-responsiveness-test.el --- Interactive regression tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Verify work avoided on hot paths, cache freshness, and direct interaction.
;; Operation counts are stable across machines; timings live in the benchmark.

;;; Code:

(require 'ert)
(require 'valsi)

(defun valsi-responsiveness--chain (count &optional cycle)
  "Return a COUNT-task dependency chain, closing a cycle when CYCLE is non-nil."
  (concat "# Plan\n"
          (mapconcat
           (lambda (id)
             (format "- [ ] T%03d Task%s\n" id
                     (if (and (= id 1) (not cycle)) ""
                       (format " (depends on T%03d)"
                               (if (= id 1) count (1- id))))))
           (number-sequence 1 count) "")))

(ert-deftest valsi-responsiveness-nested-task-states ()
  "Deep completed hierarchies do bounded work when linted or inspected."
  (let* ((tree (valsi-plan-parse
                (mapconcat
                 (lambda (n) (format "%s- [x] Nested task\n"
                                     (make-string (* 2 n) ?\s)))
                 (number-sequence 0 39) "")))
         (task (car (valsi-node-of-type tree 'task)))
         (property (symbol-function 'valsi-node-prop))
         (reads 0))
    (cl-letf (((symbol-function 'valsi-node-prop)
               (lambda (&rest args)
                 (cl-incf reads)
                 (when (> reads 10000)
                   (ert-fail "Repeatedly traversed completed descendants"))
                 (apply property args))))
      (should (eq 'done (valsi-plan-effective-state task)))
      (should-not (valsi-plan--lint-collect tree))
      (should (equal '(1 1 0) (valsi-plan--leaf-stats tree))))))

(ert-deftest valsi-responsiveness-progress-counts-leaves ()
  "Progress counts actual work once and derives parent states from leaf tasks."
  (let* ((tree (valsi-plan-parse
                (concat "- [x] T001 Parent\n"
                        "  - [x] T001.1 Completed\n"
                        "  - [-] T001.2 Active\n"
                        "  - [x] T001.3 Marked done prematurely\n"
                        "    - [ ] T001.3.1 Open\n"
                        "- [c] T002 Cancelled\n"
                        "- [?] T003 Unknown\n")))
         (tasks (valsi-node-of-type tree 'task)))
    (should (equal '(1 5 1) (valsi-plan--leaf-stats tree)))
    (should (equal '(in-progress done in-progress open open cancelled unknown)
                   (mapcar #'valsi-plan-effective-state tasks)))
    (should (equal '(0 0 0) (valsi-plan--leaf-stats (valsi-plan-parse "# Empty\n"))))
    (should (equal '("T001: marked done but has an unfinished child"
                     "T001.3: marked done but has an unfinished child"
                     "T003: unknown state char \"?\"")
                   (valsi-plan--lint-issues tree)))))

(ert-deftest valsi-responsiveness-actionable-uses-derived-parent-state ()
  "A parent's completed children satisfy dependencies even if its box is open."
  (with-temp-buffer
    (insert (concat "- [ ] T001 Parent (depends on missing)\n"
                    "  - [x] T001.1 Completed\n"
                    "- [ ] T002 Next (depends on T001)\n"))
    (let ((tree (valsi-node-shift (valsi-plan-parse (buffer-string)) 1)))
      (cl-letf (((symbol-function 'valsi-tree) (lambda () tree)))
        (should (equal "T002" (valsi-node-prop (valsi-plan-next-actionable) :id)))
        (should (looking-at "- \\[ \\] T002"))))))

(ert-deftest valsi-responsiveness-long-dependencies ()
  "Long chains and cycles lint completely without recursive graph traversal."
  (let ((max-lisp-eval-depth 100))
    (should-not (valsi-plan--lint-collect
                 (valsi-plan-parse (valsi-responsiveness--chain 2000))))
    (let* ((tree (valsi-plan-parse (valsi-responsiveness--chain 2000 t)))
           (tasks (valsi-node-of-type tree 'task))
           (findings (valsi-plan--lint-collect tree)))
      (should (= 2000 (length findings)))
      (should (seq-every-p
               (lambda (finding) (string-suffix-p "dependency cycle" (cdr finding)))
               findings))
      (should (valsi-plan--reaches-p "T2000" "T001" tasks))
      (should-not (valsi-plan--reaches-p "T2000" "missing" tasks)))))

(ert-deftest valsi-responsiveness-cycle-membership ()
  "Only members of cycles are flagged, including self edges and duplicates."
  (let* ((tree (valsi-plan-parse
                (concat "- [ ] T001 (depends on T002)\n"
                        "- [ ] T002 (depends on T003)\n"
                        "- [ ] T003 (depends on T002, T004)\n"
                        "- [ ] T004 Leaf\n"
                        "- [ ] T005 (depends on T005)\n"
                        "- [ ] T006 (depends on T999)\n"
                        "- [ ] T004 (depends on T004)\n")))
         (issues (valsi-plan--lint-issues tree)))
    (should (equal (seq-filter (lambda (s) (string-suffix-p "dependency cycle" s))
                               issues)
                   '("T002: dependency cycle" "T003: dependency cycle"
                     "T005: dependency cycle")))
    (should (member "T006: dangling dep T999" issues))
    (should (member "duplicate id T004 (2)" issues))))

(ert-deftest valsi-responsiveness-sync-once-and-idle-edit ()
  "Opening and refreshing parse once; typing waits for idle, queries stay fresh."
  (valsi-init)
  (with-temp-buffer
    (insert "# Plan\n- [ ] T001 First\n")
    (setq buffer-file-name "/tmp/valsi-responsive/PLAN.md")
    (let ((parse (symbol-function 'valsi-registry-parse-content))
          (count 0)
          (valsi-app-auto-sidebar nil))
      (cl-letf (((symbol-function 'valsi-registry-parse-content)
                 (lambda (&rest args) (cl-incf count) (apply parse args))))
        (unwind-protect
            (progn
              (valsi-artifact-minor-mode 1)
              (should (= count 1))
              (valsi-tree)
              (should (= count 1))
              (valsi-refresh)
              (should (= count 2))
              (valsi-enter-insert)
              (goto-char (point-max))
              (insert "- [ ] T002 ")
              (insert "Second\n")
              (should (= count 2))
              (should (timerp valsi--refresh-timer))
              (valsi--cancel-refresh)
              (valsi--idle-refresh (current-buffer))
              (should (= count 3))
              (should (= 2 (length (valsi-node-of-type (valsi-tree) 'task))))
              (let ((tree valsi--tree))
                (put-text-property (point-min) (point-max) 'face 'bold)
                (should (eq tree (valsi-tree)))
                (should (= count 3)))
              (insert "- [ ] T003 Third\n")
              (should (= 3 (length (valsi-node-of-type (valsi-tree) 'task))))
              (should (= count 4)))
          (valsi-artifact-minor-mode -1)
          (should-not valsi--refresh-timer))))))

(ert-deftest valsi-responsiveness-narrowed-artifact ()
  "Narrowing does not truncate AAP documents or shift their coordinates."
  (valsi-init)
  (with-temp-buffer
    (insert "# Plan\n- [ ] T001 First\n- [ ] T002 Second\n")
    (setq buffer-file-name "/tmp/valsi-narrowed/PLAN.md")
    (goto-char (point-min))
    (forward-line 2)
    (let ((second (point)))
      (narrow-to-region second (point-max))
      (unwind-protect
          (progn
            (valsi-artifact-minor-mode 1)
            (let ((tasks (valsi-node-of-type (valsi-tree) 'task)))
              (should (= 2 (length tasks)))
              (should (= second (valsi-node-beg (cadr tasks))))))
        (valsi-artifact-minor-mode -1)))))

(ert-deftest valsi-responsiveness-lazy-fontification-preserves-text ()
  "Lazy fontification applies and removes artifact faces without changing text."
  (with-temp-buffer
    (insert "- [ ] T001 First\n")
    (setq-local font-lock-defaults '(nil t))
    (let ((font-lock-mode t)
          (original (buffer-string))
          (ensure (symbol-function 'font-lock-ensure)))
      (cl-letf (((symbol-function 'font-lock-ensure)
                 (lambda (&rest _) (ert-fail "Eager whole-buffer fontification"))))
        (valsi-view-set-font-lock valsi-plan-font-lock-keywords))
      (funcall ensure)
      (should (get-text-property 4 'face))
      (valsi-view-set-font-lock nil)
      (funcall ensure)
      (should-not (get-text-property 4 'face))
      (should (equal original (buffer-substring-no-properties (point-min) (point-max)))))))

(provide 'valsi-responsiveness-test)
;;; valsi-responsiveness-test.el ends here

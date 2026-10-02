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

(provide 'valsi-responsiveness-test)
;;; valsi-responsiveness-test.el ends here

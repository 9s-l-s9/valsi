;;; valsi-node-test.el --- Node construction regressions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Check construction order and isolation while sharing the parser's builder.

;;; Code:

(require 'ert)
(require 'valsi)

(ert-deftest valsi-node-parse-builder-preserves-grammar-results ()
  "Every grammar keeps the same nodes, order, properties, and coordinates."
  (dolist (parse '(valsi-plan-parse valsi-instruction-parse valsi-memory-parse
                  valsi-promptfile-parse valsi-overview-parse
                  valsi-decision-parse valsi-changelog-parse
                  valsi-registry--parse-generic))
    (let* ((text (concat "---\nname: Example\n---\n# Title\n"
                         "## [1.0.0] - 2026-10-02\n### Added\n"
                         "- [ ] T001 Parent\n  - [x] T001.1 Child\n"
                         "- MUST keep order\n@./other.md\n[[memory]]\n"
                         "## Second\n- [ ] T002 Last\n"))
           (optimized (funcall parse text))
           (boundary (symbol-function 'valsi-parse-in-content)))
      (cl-letf (((symbol-function 'valsi-parse-in-content)
                 (lambda (content parser)
                   (funcall boundary content
                            (lambda ()
                              (let ((valsi-node--child-tails nil))
                                (funcall parser)))))))
        (should (equal (valsi-node-to-plist optimized)
                       (valsi-node-to-plist (funcall parse text))))))))

(ert-deftest valsi-node-parse-builder-handles-existing-and-copied-children ()
  "Appending to existing or copied nodes preserves independent child lists."
  (let ((a (valsi-node-create :type 'a))
        (b (valsi-node-create :type 'b))
        (c (valsi-node-create :type 'c)))
    (valsi-parse-in-content
     ""
     (lambda ()
       (let ((root (valsi-node-create :children (list a))))
         (should (eq root (valsi-node-add-child root b)))
         (let ((copy (valsi-node-deep-copy root)))
           (valsi-node-add-child copy c)
           (should (= 3 (length (valsi-node-children copy))))
           (should (equal (list a b) (valsi-node-children root))))
         ;; Replacing or extending a child list must invalidate its old tail.
         (setf (valsi-node-children root) (list b))
         (valsi-node-add-child root a)
         (nconc (valsi-node-children root) (list b))
         (valsi-node-add-child root c)
         (should (equal (list b a b c) (valsi-node-children root)))
         root)))))

(ert-deftest valsi-node-parse-builder-is-scoped-to-one-parse ()
  "Nested parses and subsequent appends cannot reuse another parse's tails."
  (should-not valsi-node--child-tails)
  (let ((root
         (valsi-parse-in-content
          ""
          (lambda ()
            (let ((outer valsi-node--child-tails)
                  (root (valsi-node-create)))
              (valsi-node-add-child root (valsi-node-create :type 'before))
              (valsi-node-add-child
               root (valsi-parse-in-content
                     "" (lambda ()
                          (should-not (eq outer valsi-node--child-tails))
                          (valsi-node-create :type 'nested))))
              (should (eq outer valsi-node--child-tails))
              root)))))
    (should-not valsi-node--child-tails)
    (valsi-node-add-child root (valsi-node-create :type 'after))
    (should (equal '(before nested after)
                   (mapcar #'valsi-node-type (valsi-node-children root))))))

(provide 'valsi-node-test)
;;; valsi-node-test.el ends here

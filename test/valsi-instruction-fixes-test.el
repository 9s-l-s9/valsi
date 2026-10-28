;;; valsi-instruction-fixes-test.el --- Instruction grammar regressions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Regression tests for instruction-grammar bugs: case-sensitive emphasis
;; (#59), inline @imports (#60), scaffold paths and titles (#61), and
;; frontmatter value forms (#62).

;;; Code:

(require 'ert)
(require 'valsi-instruction)

;;;; #59 -- emphasis markers are uppercase only

(ert-deftest valsi-test-instruction-emphasis-case-sensitive ()
  "Lowercase prose is not emphasis; uppercase markers are, regardless of fold."
  (let ((case-fold-search t))
    (let ((root (valsi-instruction-parse
                 "# T\n- always run tests\n- you must not do x\n- never mind\n- NEVER push\n")))
      (should (equal '(nil nil nil t)
                     (mapcar (lambda (i) (valsi-node-prop i :emphasis))
                             (valsi-node-of-type root 'item)))))
    (should (= 0 (valsi-instruction-match "/x/notes.md" "we should always do this")))
    (should (= 1 (valsi-instruction-match "/x/notes.md" "ALWAYS do this")))))

(provide 'valsi-instruction-fixes-test)
;;; valsi-instruction-fixes-test.el ends here

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

(provide 'valsi-plan-commands-test)
;;; valsi-plan-commands-test.el ends here

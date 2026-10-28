;;; valsi-projects-working-set-test.el --- Projects quit and removal tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Regression tests for leaving Projects after its origin buffers died and
;; for removing the project the overview was opened from.

;;; Code:

(require 'ert)
(require 'valsi-projects-test)

(ert-deftest valsi-projects-quit-with-killed-origin-falls-back-to-hub ()
  "Quitting after the origin buffer was killed shows the origin hub (#54)."
  (valsi-projects-test--with-projects
    (let ((source (find-file-noselect fa)))
      (switch-to-buffer source)
      (delete-other-windows)
      (valsi-projects)
      (kill-buffer source)
      (with-current-buffer "*Valsi Projects*" (valsi-projects-quit))
      (should-not (get-buffer-window "*Valsi Projects*"))
      (with-current-buffer (window-buffer (selected-window))
        (should (derived-mode-p 'valsi-app-mode))
        (should (equal a valsi-app--root))))))

(ert-deftest valsi-projects-removed-current-project-stays-removed ()
  "Reopening Projects from a removed project does not re-add it (#56)."
  (valsi-projects-test--with-projects
    (let ((valsi-projects--removed nil))
      (switch-to-buffer (find-file-noselect fa))
      (delete-other-windows)
      (valsi-projects)
      (should (equal (list a) (valsi-project-roots)))
      (with-current-buffer "*Valsi Projects*"
        (valsi-projects-test--row a)
        (valsi-projects-remove))
      (should-not (valsi-project-roots))
      (with-current-buffer "*Valsi Projects*" (valsi-projects-quit))
      (set-buffer (window-buffer (selected-window)))
      (valsi-projects)
      (should-not (valsi-project-roots))
      ;; Opening it explicitly makes it a working project again.
      (valsi-project-switch a)
      (should (equal (list a) (valsi-project-roots)))
      (valsi-projects)
      (should (equal (list a) (valsi-project-roots))))))

(provide 'valsi-projects-working-set-test)
;;; valsi-projects-working-set-test.el ends here

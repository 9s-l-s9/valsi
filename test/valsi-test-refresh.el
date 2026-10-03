;;; valsi-test-refresh.el --- Cooperative refresh test helpers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Advance timers deterministically for refresh and keyboard workflow tests.

;;; Code:

(require 'ert)
(require 'valsi-app-live-refresh)

(defun valsi-test-refresh-step (root)
  "Run one scheduled work turn for ROOT without waiting on wall time."
  (let* ((project (valsi-app-live-refresh--project root))
         (timer (valsi-app-live-refresh--project-timer project))
         (iterator (valsi-app-live-refresh--project-iterator project)))
    (when timer (cancel-timer timer))
    (cl-letf (((symbol-function 'input-pending-p) (lambda () nil)))
      (if iterator (valsi-app-live-refresh--continue project iterator)
        (valsi-app-live-refresh--dispatch project)))))

(defun valsi-test-refresh-drain (root)
  "Run all scheduled ROOT work, failing if it does not finish."
  (let ((project (valsi-app-live-refresh--project root)) (turns 0))
    (while (valsi-app-live-refresh--project-timer project)
      (cl-incf turns)
      (when (> turns 10000) (ert-fail "Project refresh did not finish"))
      (valsi-test-refresh-step root))
    turns))

(provide 'valsi-test-refresh)
;;; valsi-test-refresh.el ends here

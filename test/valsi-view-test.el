;;; valsi-view-test.el --- Dashboard interaction regressions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Exercise refresh and navigation from the displayed dashboard, with multiple
;; artifacts open and without relying on the most recently visited buffer.

;;; Code:

(require 'ert)
(require 'valsi)

(ert-deftest valsi-view-refresh-uses-edited-source ()
  "Refreshing an instruction map reads edits from its original artifact."
  (valsi-init)
  (let ((source (generate-new-buffer " *valsi-view-source*")) table)
    (unwind-protect
        (save-window-excursion
          (with-current-buffer source
            (insert "# Rules\n- MUST keep this\n")
            (setq buffer-file-name "/tmp/valsi-view/AGENTS.md")
            (valsi-instruction-dashboard)
            (setq table (current-buffer)))
          (with-current-buffer source
            (goto-char (point-max))
            (insert "## More\n- Another rule\n")
            (narrow-to-region (point-min) 8))
          (with-current-buffer table
            (revert-buffer)
            (should (equal '("Rules" "More")
                           (mapcar (lambda (entry) (aref (cadr entry) 1))
                                   tabulated-list-entries)))
            (should-not (bound-and-true-p valsi--tree)))
          (with-current-buffer source (should (buffer-narrowed-p)))
          (kill-buffer source)
          (with-current-buffer table
            (should-error (revert-buffer) :type 'user-error)
            (should (= 2 (length tabulated-list-entries)))))
      (when (buffer-live-p source) (kill-buffer source))
      (when (buffer-live-p table) (kill-buffer table))
      (valsi--request 'artifact/didClose (list :uri "/tmp/valsi-view/AGENTS.md")))))

(ert-deftest valsi-view-reopen-preserves-selection-and-sorting ()
  "Returning to the same table keeps its selected row and chosen sorting."
  (let ((source (generate-new-buffer " *valsi-view-source*")) table)
    (unwind-protect
        (save-window-excursion
          (with-current-buffer source
            (setq table (valsi-view-tabulated
                         " *valsi-view-test*" [("Name" 30 t)]
                         '((1 ["First"]) (2 ["Second"])) nil '("Name"))))
          (with-current-buffer table
            (setq tabulated-list-sort-key '("Name" . t))
            (tabulated-list-print)
            (goto-char (point-min))
            (should (= 2 (tabulated-list-get-id))))
          (with-current-buffer source
            (valsi-view-tabulated
             " *valsi-view-test*" [("Name" 30 t)]
             '((1 ["First"]) (2 ["Second"]) (3 ["Third"])) nil '("Name")))
          (with-current-buffer table
            (should (equal '("Name" . t) tabulated-list-sort-key))
            (should (= 2 (tabulated-list-get-id)))))
      (kill-buffer source)
      (when (buffer-live-p table) (kill-buffer table)))))

(ert-deftest valsi-view-navigation-is-local-and-remembers-source ()
  "A graph cannot change outline keys or redirect it to another artifact."
  (valsi-init)
  (let ((source (generate-new-buffer " *valsi-view-original*"))
        (other (generate-new-buffer " *valsi-view-other*"))
        (base-binding (lookup-key valsi-view-list-mode-map (kbd "RET")))
        outline graph)
    (unwind-protect
        (save-window-excursion
          (with-current-buffer source
            (insert "# Original\n## Target\n")
            (setq buffer-file-name "/tmp/valsi-view/README.md")
            (valsi-overview-dashboard)
            (setq outline (current-buffer)))
          (with-current-buffer other
            (insert "# Distractor\n")
            (setq-local valsi-artifact-minor-mode t)
            (cl-letf (((symbol-function 'valsi-graph--entries) (lambda () nil)))
              (valsi-graph)
              (setq graph (current-buffer))))
          (should (eq (lookup-key valsi-view-list-mode-map (kbd "RET"))
                      base-binding))
          (with-current-buffer graph
            (should (eq #'valsi-graph-visit (key-binding (kbd "RET")))))
          (switch-to-buffer outline)
          (goto-char (point-min))
          (forward-line 1)
          (should (eq #'valsi-overview--visit (key-binding (kbd "RET"))))
          (call-interactively (key-binding (kbd "RET")))
          (should (eq source (current-buffer)))
          (should (looking-at "## Target")))
      (kill-buffer source)
      (kill-buffer other)
      (when (buffer-live-p outline) (kill-buffer outline))
      (when (buffer-live-p graph) (kill-buffer graph))
      (valsi--request 'artifact/didClose (list :uri "/tmp/valsi-view/README.md")))))

(provide 'valsi-view-test)
;;; valsi-view-test.el ends here

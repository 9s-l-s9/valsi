;;; valsi-app-test.el --- Responsive application tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'valsi-app)

(ert-deftest valsi-app-responsive-layout-breakpoints ()
  "Hub layout deliberately drops metadata as its window narrows."
  (should (eq (valsi-app--layout 80) 'narrow))
  (should (eq (valsi-app--layout 100) 'medium))
  (should (eq (valsi-app--layout 140) 'wide)))

(ert-deftest valsi-app-mode-uses-direct-magit-like-keys ()
  "Application buffers expose direct keys while editable files retain a prefix."
  (should (eq (lookup-key valsi-app-mode-map (kbd "n"))
              #'valsi-app-context-command))
  (should (eq (lookup-key valsi-app-mode-map (kbd "t"))
              #'valsi-app-context-command))
  (should (eq (lookup-key valsi-app-mode-map (kbd "g"))
              #'valsi-app-refresh))
  (should (eq (lookup-key valsi-app-mode-map (kbd "?"))
              #'valsi-app-menu))
  (should (eq (lookup-key valsi-app-mode-map (kbd "s"))
              #'valsi-app-hide-sidebar)))

(ert-deftest valsi-app-sidebar-protects-source-width ()
  "Automatic and explicit sidebars never make the source unusably narrow."
  (let ((valsi-app-minimum-source-width 68)
        (valsi-app-sidebar-minimum-frame-width 100)
        (valsi-app-sidebar-width 34))
    (should-not (valsi-app--sidebar-width-for-frame 80))
    (should (= 31 (valsi-app--sidebar-width-for-frame 100)))
    (should (= 34 (valsi-app--sidebar-width-for-frame 140)))
    (should-not (valsi-app--sidebar-width-for-frame 90 t))
    (should (= 24 (valsi-app--sidebar-width-for-frame 93 t)))
    (let ((valsi-app-sidebar-width 0.25))
      (should (= 50 (valsi-app--sidebar-width-for-frame 200)))
      (should (= 25 (valsi-app--sidebar-width-for-frame 100))))))

(ert-deftest valsi-app-section-fold-and-refresh-preserve-point ()
  "Fold state and semantic point survive a native buffer redraw."
  (with-temp-buffer
    (valsi-app-mode)
    (setq valsi-app--root default-directory
          valsi-app--entries nil
          valsi-app--compact nil)
    (cl-letf (((symbol-function 'valsi-terminal-agent-list)
               (lambda (&optional _root) nil)))
      (valsi-app--render)
      (goto-char (point-min))
      (re-search-forward "^[▾▸] Artifacts")
      (beginning-of-line)
      (let ((row (get-text-property (point) 'valsi-row-id)))
        (should (equal row "section:artifacts"))
        (valsi-view-toggle-section)
        (should-not (valsi-view-section-expanded-p 'artifacts t))
        (should (equal (get-text-property (line-beginning-position)
                                          'valsi-row-id)
                       "section:artifacts"))
        (valsi-app--render)
        (should-not (valsi-view-section-expanded-p 'artifacts t))
        (should (equal (get-text-property (line-beginning-position)
                                          'valsi-row-id)
                       "section:artifacts"))))))

(ert-deftest valsi-app-hub-orders-and-hides-empty-sections ()
  "The project hub uses the planned hierarchy without empty noise."
  (with-temp-buffer
    (valsi-app-mode)
    (setq valsi-app--root default-directory
          valsi-app--entries nil
          valsi-app--compact nil)
    (cl-letf (((symbol-function 'valsi-terminal-agent-list)
               (lambda (&optional _root) nil)))
      (valsi-app--render)
      (goto-char (point-min))
      (let ((overview (search-forward "Overview"))
            (artifacts (search-forward "Artifacts"))
            (project (search-forward "Project")))
        (should (< overview artifacts project)))
      (goto-char (point-min))
      (let ((case-fold-search nil))
        (should-not (re-search-forward "^[▾▸] Attention" nil t))
        (should-not (re-search-forward "^[▾▸] Agents" nil t)))
      (should-not (search-forward "Relevant artifacts" nil t)))))

(provide 'valsi-app-test)
;;; valsi-app-test.el ends here

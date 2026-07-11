;;; valsi-demo.el --- Launch a demo Emacs with Valsi -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A ready-to-run configuration.  Launch with:
;;
;;   guix shell nss-certs emacs emacs-markdown-mode -- emacs -Q -L lisp -l valsi-demo.el
;;   (or simply: make run)
;;
;; It loads Valsi, turns on `valsi-global-mode', opens PLAN.md with the plan
;; grammar active, and prints the keymap so you can drive it.

;;; Code:

(add-to-list 'load-path (expand-file-name "lisp" default-directory))
(require 'markdown-mode nil t)
(require 'valsi)

(valsi-init)
(valsi-global-mode 1)

;; Open the flagship artifact -- a real plan/tasks file.
(let ((plan (expand-file-name "PLAN.md" default-directory)))
  (when (file-exists-p plan)
    (find-file plan)
    (unless (bound-and-true-p valsi-artifact-minor-mode)
      (valsi-artifact-minor-mode 1))))

(with-current-buffer (get-buffer-create "*Valsi welcome*")
  (erase-buffer)
  (insert "Valsi demo — grammar-aware views for agent artifacts\n")
  (insert "====================================================\n\n")
  (insert "Grammars registered: "
          (mapconcat #'symbol-name (valsi-registry-all) ", ") "\n\n")
  (insert "Open any of these and the right grammar auto-activates:\n")
  (insert "  PLAN.md / specs/*/tasks.md   -> plan/tasks\n")
  (insert "  AGENTS.md / CLAUDE.md        -> instruction\n")
  (insert "  SKILL.md                     -> prompt-file\n")
  (insert "  MEMORY.md, memory/*.md       -> memory\n")
  (insert "  CHANGELOG.md                 -> changelog (Keep a Changelog)\n")
  (insert "  doc/adr/*.md                 -> decision (ADR)\n")
  (insert "  README.md / ARCHITECTURE.md  -> overview\n\n")
  (insert "Keybindings (C-c n prefix), dispatched to the active grammar:\n")
  (insert "  C-c n n / p   next / previous element\n")
  (insert "  C-c n t       toggle / cycle at point\n")
  (insert "  C-c n g       goto by id / name\n")
  (insert "  C-c n i       info at point\n")
  (insert "  C-c n %       progress\n")
  (insert "  C-c n a       next actionable task\n")
  (insert "  C-c n l       lint / validate\n")
  (insert "  C-c n RET     follow reference\n")
  (insert "  C-c n d       family dashboard\n")
  (insert "  C-c n G       cross-artifact graph\n")
  (insert "  C-c n c       project artifact hub\n")
  (insert "  M-x valsi-agent  stock agent CLI in an Eat terminal\n")
  (insert "  C-c n m       transient menu (discoverable)\n")
  (goto-char (point-min))
  (view-mode 1))
(display-buffer "*Valsi welcome*")

(message "Valsi demo ready. C-c n m opens the menu.")

;;; valsi-demo.el ends here

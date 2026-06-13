;;; valsi-view.el --- View drivers (font-lock + tabulated-list) for Valsi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The client-side view driver.  Renders server/model output (a node tree)
;; into Emacs surfaces: font-lock keyword lists and `tabulated-list' agendas.
;; Faces live here so every grammar shares one visual vocabulary.

;;; Code:

(require 'tabulated-list)

;;;; Faces

(defgroup valsi nil
  "Grammar-aware views for agent artifacts."
  :group 'text
  :prefix "valsi-")

(defgroup valsi-faces nil
  "Faces for Valsi artifact views."
  :group 'valsi)

(defface valsi-open-face
  '((t :inherit warning :weight bold))
  "Face for an open task's checkbox."
  :group 'valsi-faces)

(defface valsi-in-progress-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for an in-progress task's checkbox."
  :group 'valsi-faces)

(defface valsi-done-face
  '((t :inherit shadow :strike-through nil))
  "Face for a completed task line (dimmed)."
  :group 'valsi-faces)

(defface valsi-done-box-face
  '((t :inherit success :weight bold))
  "Face for a done checkbox marker."
  :group 'valsi-faces)

(defface valsi-cancelled-face
  '((t :inherit shadow :strike-through t))
  "Face for a cancelled task."
  :group 'valsi-faces)

(defface valsi-unknown-face
  '((t :inherit error :weight bold))
  "Face for an unknown checkbox state char (surfaced, not fixed)."
  :group 'valsi-faces)

(defface valsi-id-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for a task id."
  :group 'valsi-faces)

(defface valsi-tag-face
  '((t :inherit font-lock-type-face :box t))
  "Face for a bracketed tag."
  :group 'valsi-faces)

(defface valsi-story-face
  '((t :inherit font-lock-keyword-face :box t))
  "Face for a user-story tag."
  :group 'valsi-faces)

(defface valsi-dep-face
  '((t :inherit font-lock-variable-name-face :slant italic))
  "Face for an inline dependency clause."
  :group 'valsi-faces)

(defface valsi-trace-face
  '((t :inherit link :underline t))
  "Face for a trace / requirement / path reference."
  :group 'valsi-faces)

(defface valsi-meta-face
  '((t :inherit font-lock-doc-face))
  "Face for a group/task meta field label."
  :group 'valsi-faces)

(defface valsi-emphasis-face
  '((t :inherit error :weight bold))
  "Face for imperative emphasis markers (IMPORTANT / YOU MUST)."
  :group 'valsi-faces)

(defface valsi-link-face
  '((t :inherit link))
  "Face for a wiki-style [[link]] or @import."
  :group 'valsi-faces)

(defface valsi-frontmatter-key-face
  '((t :inherit font-lock-keyword-face))
  "Face for a frontmatter key."
  :group 'valsi-faces)

;;;; Font-lock installation

(defun valsi-view-set-font-lock (keywords)
  "Install grammar KEYWORDS into the current buffer's font-lock."
  (when (bound-and-true-p valsi-view--installed-keywords)
    (font-lock-remove-keywords nil valsi-view--installed-keywords))
  (setq-local valsi-view--installed-keywords keywords)
  (when keywords
    (font-lock-add-keywords nil keywords 'append))
  (when font-lock-mode
    (font-lock-flush)
    (font-lock-ensure)))

(defvar-local valsi-view--installed-keywords nil
  "The keyword list currently installed by Valsi, for clean removal.")

;;;; Tabulated-list agenda factory

(defvar-local valsi-view--refresh-fn nil
  "Buffer-local function recomputing tabulated entries for refresh.")

(define-derived-mode valsi-view-list-mode tabulated-list-mode "Valsi-List"
  "Base mode for Valsi tabulated agenda/dashboard views."
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'valsi-view--revert nil t))

(defun valsi-view--revert ()
  "Recompute entries via the buffer-local refresh function."
  (when valsi-view--refresh-fn
    (setq tabulated-list-entries (funcall valsi-view--refresh-fn))))

(defun valsi-view-tabulated (name columns entries &optional refresh-fn sort-key)
  "Pop up a tabulated-list buffer NAME with COLUMNS and ENTRIES.
COLUMNS is a vector of (HEADER WIDTH SORT).  ENTRIES is a
`tabulated-list-entries' value.  REFRESH-FN, if given, recomputes ENTRIES on
revert.  SORT-KEY optionally sets the initial sort column.  Returns the
buffer."
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (valsi-view-list-mode)
      (setq tabulated-list-format columns)
      (setq valsi-view--refresh-fn refresh-fn)
      (setq tabulated-list-entries entries)
      (when sort-key (setq tabulated-list-sort-key sort-key))
      (tabulated-list-init-header)
      (tabulated-list-print))
    (pop-to-buffer buf)
    buf))

(provide 'valsi-view)
;;; valsi-view.el ends here

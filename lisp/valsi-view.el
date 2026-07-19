;;; valsi-view.el --- View drivers (font-lock + tabulated-list) for Valsi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The client-side view driver.  Renders server/model output (a node tree)
;; into Emacs surfaces: font-lock keyword lists and `tabulated-list' agendas.
;; Faces live here so every grammar shares one visual vocabulary.

;;; Code:

(require 'tabulated-list)
(require 'subr-x)
(require 'transient)
(require 'valsi-node)

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

(defface valsi-section-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for headings in native Valsi application buffers."
  :group 'valsi-faces)

(defface valsi-state-face
  '((t :inherit shadow))
  "Face for quiet state and count metadata."
  :group 'valsi-faces)

(defface valsi-attention-face
  '((t :inherit warning))
  "Face reserved for state that needs user attention."
  :group 'valsi-faces)

;;;; Native application sections

(defvar-local valsi-view-section-state nil
  "Hash table mapping stable section identifiers to expanded state.")

(defun valsi-view-section-expanded-p (id &optional default)
  "Return whether section ID is expanded, using DEFAULT when unseen."
  (unless (hash-table-p valsi-view-section-state)
    (setq valsi-view-section-state (make-hash-table :test #'equal)))
  (if (eq (gethash id valsi-view-section-state 'valsi-unseen) 'valsi-unseen)
      default
    (gethash id valsi-view-section-state)))

(defvar-local valsi-view-section-render-function nil
  "Function re-rendering the current sectioned buffer after a fold toggle.
Nil falls back to `revert-buffer'.")

(defun valsi-view-toggle-section ()
  "Toggle the native Valsi section at point."
  (interactive)
  (let ((id (get-text-property (line-beginning-position) 'valsi-section-id)))
    (unless id (user-error "No collapsible section at point"))
    (puthash id
             (not (valsi-view-section-expanded-p id t))
             valsi-view-section-state)
    (if valsi-view-section-render-function
        (funcall valsi-view-section-render-function)
      (revert-buffer))))

(defun valsi-view-insert-section (id title body &optional summary default)
  "Insert collapsible section ID named TITLE, followed by BODY.
SUMMARY is quiet text placed on the heading row.  DEFAULT controls the initial
expanded state.  BODY is a function called with no arguments."
  (let* ((expanded (valsi-view-section-expanded-p id default))
         (start (point))
         (marker (if expanded "▾" "▸")))
    (insert (propertize marker 'face 'valsi-state-face) " ")
    (insert (propertize title 'face 'valsi-section-face))
    (when (and summary (not (string-empty-p summary)))
      (insert "  " (propertize summary 'face 'valsi-state-face)))
    (insert "\n")
    (add-text-properties
     start (point)
     `(valsi-section-id ,id valsi-row-id ,(format "section:%s" id)
                       mouse-face highlight help-echo "TAB toggles section"))
    (when expanded (funcall body))))

;;;; Semantic outline: the one compressed view over artifact node trees
;;
;; The `valsi-node' tree is the single underlying data structure for every
;; compressed presentation of an artifact.  This renderer is its single
;; sectioned presentation, shared by the contextual sidebar (shallow) and
;; the full outline view (deep).  Family-specific tabulated dashboards are
;; not part of default navigation.

(defun valsi-view--outline-label (node)
  "Return the row label for NODE."
  (let ((id (or (valsi-node-prop node :id)
                (valsi-node-prop node :name)
                (valsi-node-prop node :title)))
        (state (valsi-node-prop node :state)))
    (concat (if id (format "%s" id)
              (capitalize (symbol-name (valsi-node-type node))))
            (if state (format " · %s" state) ""))))

(defun valsi-view--outline-jump (button)
  "Select the source artifact of BUTTON and move point to its node."
  (let ((source (button-get button 'valsi-source))
        (pos (button-get button 'valsi-pos)))
    (unless (buffer-live-p source)
      (user-error "The source artifact buffer is gone"))
    (if-let* ((window (get-buffer-window source t)))
        (select-window window)
      (switch-to-buffer source))
    (when pos (goto-char pos))))

(defun valsi-view--outline-entry-nodes (tree)
  "Return TREE's children, descending through singleton wrapper nodes.
A document usually has one top-level group; its children are the outline."
  (let ((children (valsi-node-children tree)))
    (while (and (= (length children) 1)
                (valsi-node-children (car children)))
      (setq children (valsi-node-children (car children))))
    children))

(defun valsi-view-insert-outline (tree source &optional depth row-limit)
  "Insert outline rows for TREE's children, jumping into artifact SOURCE.
DEPTH limits nesting (default 2); ROW-LIMIT truncates each level."
  (valsi-view--insert-outline-nodes
   (valsi-view--outline-entry-nodes tree) source (or depth 2) row-limit 0))

(defun valsi-view--outline-node-visible-p (node)
  "Return non-nil when NODE is a real outline entry.
Untitled, stateless leaves are structural noise, not outline entries."
  (or (valsi-node-prop node :id)
      (valsi-node-prop node :name)
      (valsi-node-prop node :title)
      (valsi-node-prop node :state)
      (valsi-node-children node)))

(defun valsi-view--insert-outline-nodes (nodes source depth row-limit indent)
  "Insert outline rows for NODES from SOURCE at INDENT.
See `valsi-view-insert-outline' for DEPTH and ROW-LIMIT."
  (let* ((nodes (seq-filter #'valsi-view--outline-node-visible-p nodes))
         (visible (if row-limit (seq-take nodes row-limit) nodes)))
    (dolist (node visible)
      (let ((start (point))
            (label (valsi-view--outline-label node)))
        (insert (make-string (+ 2 (* 2 indent)) ?\s))
        (insert-text-button
         label
         'follow-link t
         'help-echo "RET jumps to this node in the artifact"
         'valsi-source source
         'valsi-pos (valsi-node-beg node)
         'action #'valsi-view--outline-jump)
        (insert "\n")
        (add-text-properties
         start (point)
         `(valsi-row-id ,(format "outline:%d:%s" indent label))))
      (when (> depth 1)
        (valsi-view--insert-outline-nodes
         (valsi-node-children node) source (1- depth) row-limit (1+ indent))))
    (when (and row-limit (> (length nodes) row-limit))
      (insert (propertize
               (format "%s… %d more\n"
                       (make-string (+ 2 (* 2 indent)) ?\s)
                       (- (length nodes) row-limit))
               'face 'valsi-state-face)))))

(defun valsi-view-preserving-render (render)
  "Call RENDER while preserving semantic point, window starts, and column."
  (let* ((row (get-text-property (line-beginning-position) 'valsi-row-id))
         (line (line-number-at-pos))
         (column (current-column))
         (windows (get-buffer-window-list (current-buffer) nil t))
         (starts (mapcar (lambda (window)
                           (cons window (window-start window)))
                         windows))
         (inhibit-read-only t))
    (funcall render)
    (goto-char (point-min))
    (let ((match (and row
                      (text-property-search-forward
                       'valsi-row-id row #'equal))))
      (if match
          (goto-char (prop-match-beginning match))
        (forward-line (1- (min line (line-number-at-pos (point-max)))))))
    (move-to-column column)
    (dolist (item starts)
      (when (window-live-p (car item))
        (set-window-start (car item)
                          (min (cdr item) (point-max))
                          t)))))

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

(defun valsi-view-fold-at-point ()
  "Fold the current section, or explain that the view has no foldable row."
  (interactive)
  (if (get-text-property (line-beginning-position) 'valsi-section-id)
      (valsi-view-toggle-section)
    (user-error "No foldable section at point")))

(transient-define-prefix valsi-view-menu ()
  "Valsi dashboard command menu."
  [["Navigate"
    ("n" "next row" valsi-view-list-next)
    ("p" "previous row" valsi-view-list-previous)
    ("TAB" "fold" valsi-view-fold-at-point)]
   ["View"
    ("g" "refresh" revert-buffer)
    ("q" "back" quit-window)]])

(define-obsolete-function-alias 'valsi-view-list-help 'valsi-view-menu "1.1")

(defun valsi-view-list-next ()
  "Move to the next dashboard row."
  (interactive)
  (forward-line 1)
  (beginning-of-line))

(defun valsi-view-list-previous ()
  "Move to the previous dashboard row."
  (interactive)
  (forward-line -1)
  (beginning-of-line))

(defvar valsi-view-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "n") #'valsi-view-list-next)
    (define-key map (kbd "p") #'valsi-view-list-previous)
    (define-key map (kbd "TAB") #'valsi-view-fold-at-point)
    (define-key map (kbd "<tab>") #'valsi-view-fold-at-point)
    (define-key map (kbd "g") #'revert-buffer)
    (define-key map (kbd "?") #'valsi-view-menu)
    (define-key map (kbd "SPC") #'valsi-view-menu)
    (define-key map (kbd "M-n") #'valsi-view-menu)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Universal Browse bindings inherited by tabulated Valsi views.")

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
    (switch-to-buffer buf)
    buf))

(provide 'valsi-view)
;;; valsi-view.el ends here

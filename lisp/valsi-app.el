;;; valsi-app.el --- Magit-like project hub for Valsi artifacts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Project-level application entry for Valsi.  It summarizes grammar-recognized
;; artifacts and associated terminal agents, while delegating ordinary project
;; files, Dired, Git, compilation, and window management to Emacs.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'transient)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'valsi-registry)
(require 'valsi-view)
(require 'valsi-app-live-refresh)
(require 'valsi-terminal-agent)

(declare-function valsi--maybe-enable "valsi")
(declare-function valsi-enter-insert "valsi")
(declare-function valsi-outline "valsi")
(defvar valsi-artifact-minor-mode)
(defvar valsi--interaction-state)

(defgroup valsi-app nil
  "Project application for agent artifacts."
  :group 'valsi)

(defcustom valsi-app-max-file-bytes 300000
  "Maximum bytes read while classifying one unopened artifact candidate."
  :type 'integer
  :group 'valsi-app)

(defcustom valsi-app-relevant-limit 8
  "Maximum number of relevant artifact files shown in the project hub."
  :type 'integer
  :group 'valsi-app)

(defcustom valsi-app-auto-sidebar t
  "When non-nil, visiting a Valsi artifact displays the compact project sidebar."
  :type 'boolean
  :group 'valsi-app)

(defcustom valsi-app-show-generic-markdown t
  "When non-nil, show unsupported Markdown in its own folded hub section."
  :type 'boolean
  :group 'valsi-app)

(defcustom valsi-app-sidebar-width 0.25
  "Preferred width of the automatic Valsi artifact sidebar.
An integer is a fixed number of columns; a float is a fraction of the
frame width."
  :type '(choice (integer :tag "Columns")
                 (float :tag "Fraction of frame width"))
  :group 'valsi-app)

(defcustom valsi-app-minimum-source-width 68
  "Minimum usable source or terminal width beside an automatic sidebar."
  :type 'integer
  :group 'valsi-app)

(defcustom valsi-app-sidebar-minimum-frame-width 100
  "Minimum frame width at which Valsi automatically displays its sidebar."
  :type 'integer
  :group 'valsi-app)

(defcustom valsi-app-sidebar-side 'right
  "Side on which the automatic Valsi artifact sidebar is displayed."
  :type '(choice (const left) (const right))
  :group 'valsi-app)

(defcustom valsi-app-auto-command-rail nil
  "When non-nil, show a narrow command rail beside Valsi views when space allows.
The default keybinding helper is the bottom command menu on \\`?', \\`SPC',
and \\`M-n'; the rail is an additional always-visible legend for users who
want one."
  :type 'boolean
  :group 'valsi-app)

(defcustom valsi-app-command-rail-width 20
  "Width in columns of the Valsi command rail."
  :type 'integer
  :group 'valsi-app)

(defcustom valsi-app-command-rail-minimum-frame-width 132
  "Minimum frame width for automatically showing the command rail."
  :type 'integer
  :group 'valsi-app)

(defcustom valsi-app-excluded-directory-names
  '(".git" ".direnv" ".valsi" "node_modules")
  "Directory names excluded from project artifact discovery.
This is for repository machinery and dependency stores, not content relevance.
Supported and unsupported Markdown are classified in the hub without
path-specific corpus or documentation exceptions."
  :type '(repeat string)
  :group 'valsi-app)

(defcustom valsi-app-tree-function nil
  "Optional command used by `valsi-app-project-tree'.
Nil falls back to `project-dired'."
  :type '(choice (const nil) function)
  :group 'valsi-app)

(defvar-local valsi-app--root nil)
(defvar-local valsi-app--entries nil)
(defvar-local valsi-app--compact nil)
(defvar-local valsi-app--filter nil)
(defvar-local valsi-app--source-buffer nil)
(defvar-local valsi-app--context-signature nil)
(defvar-local valsi-app--last-layout nil)
(defvar-local valsi-app--command-rail nil)

(defvar-local valsi-app--sidebar-dismissed nil
  "Non-nil in an artifact buffer after the user manually hid its sidebar.
Manual `s' remains authoritative: automatic restore skips this artifact.")

(defvar valsi-app--updating-sidebar nil
  "Non-nil while Valsi is displaying or refreshing an automatic sidebar.")

(defvar valsi-app--resize-hook-installed nil
  "Non-nil after responsive side-window monitoring is installed.")

(defun valsi-app--project ()
  "Return current project, or signal a user error."
  (or (project-current nil)
      (user-error "Current directory is not inside an Emacs project")))

(defun valsi-app--root ()
  "Return canonical root for the current Emacs project."
  (file-name-as-directory
   (file-truename (project-root (valsi-app--project)))))

(defun valsi-app--project-name (root)
  "Return display name for ROOT."
  (file-name-nondirectory (directory-file-name root)))

(defun valsi-app--buffer-name (root &optional compact)
  "Return application buffer name for ROOT.
When COMPACT is non-nil, return the artifact-index name."
  (format (if compact "*Valsi Artifacts: %s*" "*Valsi: %s*")
          (valsi-app--project-name root)))

(defun valsi-app--command-rail-buffer-name (root)
  "Return the command-rail buffer name for ROOT."
  (format "*Valsi Commands: %s*" (valsi-app--project-name root)))

(defun valsi-app--project-files (root)
  "Return Markdown project files below ROOT."
  (let* ((default-directory root)
         (project (project-current nil root)))
    (seq-filter
     (lambda (file)
       (and (string-match-p "\\.\\(?:md\\|mdc\\|markdown\\)\\'" file)
            (file-regular-p file)
            (not
             (seq-some
              (lambda (part)
                (member part valsi-app-excluded-directory-names))
              (file-name-split
               (file-relative-name file root))))))
     (mapcar
      (lambda (file)
        (if (file-name-absolute-p file) file (expand-file-name file root)))
      (project-files project)))))

(defun valsi-app--file-text (file)
  "Return current text used to classify FILE."
  (if-let* ((buffer (get-file-buffer file)))
      (with-current-buffer buffer (buffer-substring-no-properties
                                   (point-min) (point-max)))
    (with-temp-buffer
      (insert-file-contents file nil 0 valsi-app-max-file-bytes)
      (buffer-string))))

(defun valsi-app--file-state (file)
  "Return compact Emacs-visible state for FILE."
  (if-let* ((buffer (get-file-buffer file)))
      (if (buffer-modified-p buffer) "modified" "open")
    "clean"))

(defun valsi-app--artifact-summary (grammar text)
  "Return a compact semantic summary for GRAMMAR over TEXT."
  (condition-case nil
      (let* ((tree (valsi-registry-parse-content grammar text))
             (tasks (and (eq grammar 'plan)
                         (valsi-node-of-type tree 'task))))
        (when tasks
          (let ((open 0) (active 0) (done 0))
            (dolist (task tasks)
              (pcase (valsi-node-prop task :state)
                ('done (cl-incf done))
                ('in-progress (cl-incf active))
                (_ (cl-incf open))))
            (string-join
             (delq nil
                   (list (and (> active 0) (format "%d active" active))
                         (and (> open 0) (format "%d open" open))
                         (and (> done 0) (format "%d done" done))))
             " · "))))
    (error nil)))

(defun valsi-app--artifact-diagnostics (grammar text file)
  "Return (:warnings N :stale N) for GRAMMAR TEXT at FILE."
  (condition-case nil
      (let* ((tree (valsi-registry-parse-content grammar text))
             (warnings
              (pcase grammar
                ('plan
                 (if (fboundp 'valsi-plan--lint-collect)
                     (length (valsi-plan--lint-collect tree))
                   0))
                ('instruction
                 (if (fboundp 'valsi-instruction--lint-collect)
                     (length
                      (valsi-instruction--lint-collect
                       tree (file-name-directory file)))
                   0))
                (_ 0)))
             (stale
              (if (and (eq grammar 'plan)
                       (fboundp 'valsi-plan--stale-tasks))
                  (length (valsi-plan--stale-tasks tree file))
                0)))
        (list :warnings warnings :stale stale))
    (error (list :warnings 0 :stale 0))))

(defun valsi-app--scan (root)
  "Return recognized and generic Markdown entries below ROOT."
  (unless (bound-and-true-p valsi--initialized)
    (when (fboundp 'valsi-init) (valsi-init)))
  (let (entries)
    (dolist (file (valsi-app--project-files root))
      (condition-case nil
          (let* ((text (valsi-app--file-text file))
                 (grammar (valsi-registry-detect file text))
                 (diagnostics
                  (unless (eq grammar 'generic)
                    (valsi-app--artifact-diagnostics grammar text file))))
            (push (list :file file :grammar grammar
                        :state (valsi-app--file-state file)
                        :summary (unless (eq grammar 'generic)
                                   (valsi-app--artifact-summary grammar text))
                        :warnings (or (plist-get diagnostics :warnings) 0)
                        :stale (or (plist-get diagnostics :stale) 0)
                        :mtime (file-attribute-modification-time
                                (file-attributes file)))
                  entries))
        (file-error nil)))
    (sort entries
          (lambda (left right)
            (string< (plist-get left :file) (plist-get right :file))))))

(defun valsi-app--group (entries)
  "Group artifact ENTRIES by grammar."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (entry entries)
      (let ((grammar (plist-get entry :grammar)))
        (puthash grammar (cons entry (gethash grammar table)) table)))
    table))

(defun valsi-app--visit-button (button)
  "Visit artifact represented by BUTTON."
  (valsi-app-hide-sidebars)
  (find-file (button-get button 'valsi-file)))

(defun valsi-app--family-button (button)
  "Expand or collapse the artifact family represented by BUTTON."
  (let ((id (format "family:%s" (button-get button 'valsi-grammar))))
    (puthash id
             (not (valsi-view-section-expanded-p id nil))
             valsi-view-section-state)
    (valsi-app--render)))

(defun valsi-app--overview-button (button)
  "Jump to BUTTON's family in the Artifacts section, expanded."
  (let ((id (format "family:%s" (button-get button 'valsi-grammar))))
    (valsi-view-section-expanded-p id nil) ; ensure the state table exists
    (puthash id t valsi-view-section-state)
    (valsi-app--render)
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward
                        'valsi-row-id id #'equal)))
      (goto-char (prop-match-beginning match))
      (beginning-of-line))))

(defun valsi-app--agent-button (button)
  "Focus the terminal agent represented by BUTTON."
  (valsi-app-hide-sidebars)
  (let ((buffer (button-get button 'valsi-buffer))
        (root valsi-app--root))
    (switch-to-buffer buffer)
    (valsi-app-show-command-rail buffer root)))

(defun valsi-app--insert-file (entry root)
  "Insert artifact ENTRY relative to ROOT."
  (let ((file (plist-get entry :file)))
    (insert "  ")
    (insert-text-button
     (file-relative-name file root)
     'follow-link t
     'valsi-file file
     'action #'valsi-app--visit-button)
    (insert (format "  %-18s%s\n"
                    (plist-get entry :state)
                    (or (plist-get entry :summary) "")))))

(defun valsi-app--context ()
  "Return contextual artifact data for the current compact application buffer."
  (when (buffer-live-p valsi-app--source-buffer)
    (with-current-buffer valsi-app--source-buffer
      (let* ((tree (and (boundp 'valsi--tree) valsi--tree))
             (node (and tree (fboundp 'valsi-node-at)
                        (valsi-node-at tree (point))))
             (id (and node
                      (or (valsi-node-prop node :id)
                          (valsi-node-prop node :name)
                          (valsi-node-prop node :title))))
             (state (and node (valsi-node-prop node :state)))
             (deps (and node (or (valsi-node-prop node :depends)
                                 (valsi-node-prop node :dependencies)))))
        (list :file buffer-file-name
              :grammar (and (boundp 'valsi--grammar) valsi--grammar)
              :capabilities (and (boundp 'valsi--capabilities)
                                 valsi--capabilities)
              :node-type (and node (valsi-node-type node))
              :node-id id
              :state state
              :dependencies deps
              :modified (buffer-modified-p))))))

(defun valsi-app-context-signature (source)
  "Return cheap semantic context signature for artifact buffer SOURCE."
  (when (buffer-live-p source)
    (with-current-buffer source
      (let* ((tree (and (boundp 'valsi--tree) valsi--tree))
             (node (and tree (fboundp 'valsi-node-at)
                        (valsi-node-at tree (point)))))
        (list source
              (and node (valsi-node-type node))
              (and node (or (valsi-node-prop node :id)
                            (valsi-node-prop node :name)
                            (valsi-node-prop node :title)))
              (and node (valsi-node-prop node :state))
              (buffer-modified-p))))))

(defconst valsi-app--artifact-command-hints
  '((next "n" "next" valsi-next)
    (prev "p" "previous" valsi-previous)
    (toggle "t" "toggle/cycle" valsi-toggle)
    (lint "l" "lint" valsi-lint)
    (goto "G" "goto id/name" valsi-goto)
    (progress "%" "progress" valsi-progress)
    (occur-state "o" "occur" valsi-occur-state)
    (dashboard "d" "outline" valsi-outline))
  "Capability, suffix key, and label shown for contextual artifact commands.")

(defun valsi-app--primary-actions (capabilities)
  "Return at most four primary action hints for CAPABILITIES."
  (seq-take
   (seq-filter (lambda (hint) (memq (car hint) capabilities))
               valsi-app--artifact-command-hints)
   4))

(defun valsi-app--insert-context (layout)
  "Insert active artifact context for responsive sidebar LAYOUT."
  (when-let* ((context (valsi-app--context)))
    (let* ((file (plist-get context :file))
          (grammar (plist-get context :grammar))
          (capabilities (plist-get context :capabilities))
          (node-id (plist-get context :node-id))
          (node-type (plist-get context :node-type))
          (state (plist-get context :state))
          (dependencies (plist-get context :dependencies))
          (entry (seq-find
                  (lambda (item)
                    (and file
                         (file-equal-p file (plist-get item :file))))
                  valsi-app--entries)))
      (insert "\n" (propertize "CURRENT\n" 'face 'valsi-section-face))
      (when file
        (insert-text-button
         (file-relative-name file valsi-app--root)
         'follow-link t
         'valsi-file file
         'action #'valsi-app--visit-button))
      (insert (propertize
               (format "  %s%s\n"
                       (capitalize (symbol-name (or grammar 'generic)))
                       (if (plist-get context :modified) " · modified" ""))
               'face 'valsi-state-face))
      (when entry
        (let ((file-state (plist-get entry :state))
              (warnings (or (plist-get entry :warnings) 0))
              (stale (or (plist-get entry :stale) 0)))
          (unless (and (equal file-state "clean")
                       (= warnings 0) (= stale 0))
            (insert
             (propertize
              (format "  %s%s%s\n"
                      file-state
                      (if (> warnings 0)
                          (format " · %d warnings" warnings) "")
                      (if (> stale 0) (format " · %d stale" stale) ""))
              'face 'valsi-attention-face)))))
      (when node-type
        (insert "\n" (propertize
                       (capitalize (symbol-name node-type))
                       'face 'bold)
                "\n")
        (when node-id
          (insert (propertize
                   (truncate-string-to-width
                    (format "%s" node-id)
                    (max 12
                         (- (or (when-let* ((window
                                             (get-buffer-window
                                              (current-buffer) t)))
                                  (window-body-width window))
                                32)
                            2))
                    nil nil "…")
                   'face 'valsi-state-face)
                  "\n"))
        (when state
          (insert "  State  " (format "%s\n" state)))
        (when (and dependencies (not (eq layout 'narrow)))
          (insert "  Needs  " (format "%s\n" dependencies))))
      (when (and capabilities (eq layout 'wide))
        (insert "\n"
                (propertize
                 (format "%d semantic actions\n" (length capabilities))
                 'face 'valsi-state-face)))
      (when-let* ((source valsi-app--source-buffer)
                  ((buffer-live-p source))
                  (tree (with-current-buffer source
                          (and (boundp 'valsi--tree) valsi--tree))))
        (insert "\n" (propertize "OUTLINE\n" 'face 'valsi-section-face))
        (valsi-view-insert-outline
         tree source 1
         (pcase layout ('narrow 6) ('medium 10) (_ 14)))))))

(defun valsi-app-context-command ()
  "Run the one-key contextual artifact command from the compact sidebar."
  (interactive)
  (let ((key (key-description (this-command-keys-vector))))
    (if (not valsi-app--compact)
        (pcase key
          ("n" (forward-button 1 t t))
          ("p" (backward-button 1 t t))
          ("t" (valsi-view-toggle-section))
          (_ (user-error "%s is contextual to the artifact sidebar" key)))
      (unless (buffer-live-p valsi-app--source-buffer)
        (user-error "The sidebar has no live source artifact"))
      (let* ((hint (seq-find (lambda (item) (equal key (cadr item)))
                             valsi-app--artifact-command-hints))
             (command (nth 3 hint)))
        (unless (and command (commandp command))
          (user-error "No contextual action for %s" key))
        (with-current-buffer valsi-app--source-buffer
          (call-interactively command))
        (setq valsi-app--context-signature
              (valsi-app-context-signature valsi-app--source-buffer))
        (valsi-app--render)))))

(defun valsi-app--visible-entries (entries root)
  "Return ENTRIES visible under the current filter for ROOT."
  (if (or (null valsi-app--filter) (string-empty-p valsi-app--filter))
      entries
    (seq-filter
     (lambda (entry)
       (string-match-p
        (regexp-quote valsi-app--filter)
        (downcase
         (format "%s %s"
                 (symbol-name (plist-get entry :grammar))
                 (file-relative-name (plist-get entry :file) root)))))
     entries)))

(defun valsi-app--state-counts (entries)
  "Return a readable non-clean state summary for ENTRIES."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (entry entries)
      (let ((state (plist-get entry :state)))
        (unless (equal state "clean")
          (puthash state (1+ (gethash state counts 0)) counts))))
    (mapconcat
     (lambda (state) (format "%d %s" (gethash state counts) state))
     (sort (hash-table-keys counts) #'string<)
     " · ")))

(defun valsi-app--layout (&optional width)
  "Return responsive layout symbol for WIDTH or the visible buffer width."
  (let ((width (or width
                   (when-let* ((window (get-buffer-window (current-buffer) t)))
                     (window-body-width window))
                   (frame-width))))
    (cond ((< width 90) 'narrow)
          ((< width 120) 'medium)
          (t 'wide))))

(defun valsi-app--attention-entries (entries)
  "Return artifact ENTRIES requiring attention."
  (seq-filter
   #'valsi-app--attention-reason
   entries))

(defun valsi-app--attention-reason (entry)
  "Return actionable reason label for ENTRY, or nil.
Diagnostics and semantic staleness count only for an open artifact."
  (let* ((state (plist-get entry :state))
         (open (get-file-buffer (plist-get entry :file)))
         (warnings (or (plist-get entry :warnings) 0))
         (stale (or (plist-get entry :stale) 0)))
    (cond
     ((member state '("modified" "changed on disk" "conflict" "new" "missing"))
      state)
     ((and open (> warnings 0)) "warning")
     ((and open (> stale 0)) "stale")
     (nil))))

(defun valsi-app--row (id text &optional face)
  "Insert a row with stable ID and TEXT, optionally using FACE."
  (let ((start (point)))
    (insert (if face (propertize text 'face face) text) "\n")
    (add-text-properties start (point) `(valsi-row-id ,id))))

(defun valsi-app--family-summary (items)
  "Return compact health summary for artifact ITEMS."
  (let ((warnings (apply #'+ (mapcar
                              (lambda (e) (or (plist-get e :warnings) 0))
                              items)))
        (stale (apply #'+ (mapcar
                           (lambda (e) (or (plist-get e :stale) 0))
                           items)))
        (states (valsi-app--state-counts items)))
    (string-join
     (delq nil
           (list (format "%d file%s" (length items)
                         (if (= (length items) 1) "" "s"))
                 (and (> warnings 0) (format "%d warning%s" warnings
                                             (if (= warnings 1) "" "s")))
                 (and (> stale 0) (format "%d stale" stale))
                 (and (not (string-empty-p states)) states)))
     " · ")))

(defun valsi-app--insert-family (grammar items root)
  "Insert GRAMMAR family ITEMS relative to ROOT."
  (let* ((expanded (valsi-view-section-expanded-p
                    (format "family:%s" grammar) nil))
         (start (point))
         (entry (car items)))
    (insert (propertize (if expanded "  ▾ " "  ▸ ") 'face 'valsi-state-face))
    (insert-text-button
     (capitalize (symbol-name grammar))
     'follow-link t
     'help-echo "RET/TAB expands this family's files"
     'valsi-grammar grammar
     'valsi-entry entry
     'valsi-file (plist-get entry :file)
     'action #'valsi-app--family-button)
    (insert "  " (propertize (valsi-app--family-summary items)
                              'face 'valsi-state-face)
            "\n")
    (add-text-properties
     start (point)
     `(valsi-section-id ,(format "family:%s" grammar)
                       valsi-row-id ,(format "family:%s" grammar)))
    (when expanded
      (dolist (item items)
        (valsi-app--insert-file item root)))))

(defun valsi-app--sorted-grammars (groups)
  "Return GROUPS' grammar symbols sorted by name."
  (sort (hash-table-keys groups)
        (lambda (a b) (string< (symbol-name a) (symbol-name b)))))

(defun valsi-app--insert-header (root recognized markdown agents)
  "Insert the hub header for ROOT over RECOGNIZED, MARKDOWN, and AGENTS."
  (insert (propertize (format "Valsi  %s\n" (valsi-app--project-name root))
                      'face 'bold))
  (insert (propertize
           (if valsi-app--compact
               (format "%d artifacts · %d attention\n"
                       (length recognized)
                       (length (valsi-app--attention-entries recognized)))
             (format "%s  ·  %d artifacts  ·  %d markdown  ·  %d agents\n"
                     (abbreviate-file-name root)
                     (length recognized) (length markdown) (length agents)))
           'face 'valsi-state-face))
  (when valsi-app--filter
    (insert (propertize (format "filter: %s\n" valsi-app--filter)
                        'face 'valsi-state-face)))
  (insert "\n"))

(defun valsi-app--insert-overview-section (groups layout)
  "Insert the Overview section: one button row per family in GROUPS.
LAYOUT selects the narrow or wide row format."
  (valsi-view-insert-section
   'overview "Overview"
   (lambda ()
     (dolist (grammar (valsi-app--sorted-grammars groups))
       (let ((items (reverse (gethash grammar groups)))
             (start (point)))
         (insert "  ")
         (insert-text-button
          (format (if (eq layout 'narrow) "%-12s" "%-16s")
                  (capitalize (symbol-name grammar)))
          'follow-link t
          'help-echo "RET shows this family's files"
          'valsi-grammar grammar
          'action #'valsi-app--overview-button)
         (insert (propertize
                  (if (eq layout 'narrow)
                      (format " %d" (length items))
                    (format " %s" (valsi-app--family-summary items)))
                  'face 'valsi-state-face)
                 "\n")
         (add-text-properties
          start (point)
          `(valsi-row-id ,(format "overview:%s" grammar))))))
   (format "%d families" (hash-table-count groups)) t))

(defun valsi-app--insert-attention-section (attention root layout)
  "Insert the Attention section for ATTENTION entries under ROOT.
LAYOUT caps how many rows are shown before the overflow row."
  (valsi-view-insert-section
   'attention "Attention"
   (lambda ()
     (let* ((limit (pcase layout
                     ('narrow 3)
                     ('medium 5)
                     (_ (length attention))))
            (visible (seq-take attention limit)))
       (dolist (entry visible)
         (let ((file (plist-get entry :file)))
           (valsi-app--row
            (concat "attention:" file)
            (format "  %-18s %s%s"
                    (valsi-app--attention-reason entry)
                    (if (eq layout 'wide)
                        (file-relative-name file root)
                      (file-name-nondirectory file))
                    (if (equal (valsi-app--attention-reason entry) "warning")
                        (format " · %d warnings" (plist-get entry :warnings))
                      ""))
            'valsi-attention-face)))
       (when (> (length attention) limit)
         (valsi-app--row
          "attention:more"
          (format "  … %d more; RET opens artifact details"
                  (- (length attention) limit))
          'valsi-state-face))))
   (format "%d item%s" (length attention)
           (if (= (length attention) 1) "" "s"))
   t))

(defun valsi-app--insert-active-section (entries agents root)
  "Insert the Active section: modified/open ENTRIES and running AGENTS.
ROOT is the project root; the section is omitted when empty."
  (let ((active (seq-filter
                 (lambda (entry)
                   (member (plist-get entry :state) '("modified" "open")))
                 entries)))
    (when (or active agents)
      (insert "\n")
      (valsi-view-insert-section
       'active "Active"
       (lambda ()
         (dolist (entry active)
           (valsi-app--insert-file entry root))
         (dolist (agent agents)
           (valsi-app--row
            (format "active-agent:%s"
                    (valsi-terminal-agent-instance-name agent))
            (format "  agent %-12s %s"
                    (valsi-terminal-agent-instance-name agent)
                    (or (valsi-terminal-agent-instance-task agent) "idle")))))
       nil t))))

(defun valsi-app--insert-artifacts-section (recognized groups root)
  "Insert the Artifacts section: RECOGNIZED entries by family in GROUPS.
ROOT is the project root."
  (valsi-view-insert-section
   'artifacts "Artifacts"
   (lambda ()
     (if recognized
         (dolist (grammar (valsi-app--sorted-grammars groups))
           (valsi-app--insert-family
            grammar (reverse (gethash grammar groups)) root))
       (valsi-app--row "artifacts:none" "  No recognized artifacts")))
   (format "%d files" (length recognized)) t))

(defun valsi-app--insert-markdown-section (markdown root)
  "Insert the collapsed Markdown section for unrecognized MARKDOWN files.
ROOT is the project root."
  (valsi-view-insert-section
   'markdown "Markdown"
   (lambda ()
     (dolist (entry markdown)
       (valsi-app--insert-file entry root)))
   (format "%d unsupported file%s"
           (length markdown)
           (if (= (length markdown) 1) "" "s"))
   nil))

(defun valsi-app--insert-agents-section (agents layout)
  "Insert the Agents section: one button row per instance in AGENTS.
LAYOUT selects the narrow or wide row format."
  (valsi-view-insert-section
   'agents "Agents"
   (lambda ()
     (dolist (instance agents)
       (let* ((buffer (valsi-terminal-agent-instance-buffer instance))
              (status (if (and (buffer-live-p buffer)
                               (process-live-p (get-buffer-process buffer)))
                          "running" "stopped"))
              (start (point)))
         (insert "  ")
         (insert-text-button
          (valsi-terminal-agent-instance-name instance)
          'follow-link t 'valsi-buffer buffer
          'action #'valsi-app--agent-button)
         (insert
          (if (eq layout 'narrow)
              (format "  %s\n" status)
            (format "  %-8s %-8s %s\n"
                    status
                    (valsi-terminal-agent-instance-backend instance)
                    (or (valsi-terminal-agent-instance-task instance)
                        "idle"))))
         (add-text-properties
          start (point)
          `(valsi-row-id
            ,(format "agent:%s"
                     (valsi-terminal-agent-instance-name instance)))))))
   (format "%d running" (length agents)) t))

(defun valsi-app--insert-project-section ()
  "Insert the Project section and the hub footer key hints."
  (valsi-view-insert-section
   'project "Project"
   (lambda ()
     (valsi-app--row "project:files" "  f  find file     D  Dired")
     (valsi-app--row "project:buffers" "  b  buffers       T  tree")
     (valsi-app--row "project:agent" "  a  start agent    @  hand off"))
   nil nil)
  (insert "\n"
          (propertize
           "TAB fold · RET open · g refresh · / filter · ? commands · q quit\n"
           'face 'valsi-state-face)))

(defun valsi-app--render-contents ()
  "Insert the current Valsi hub or sidebar contents."
  (let* ((root valsi-app--root)
         (entries (valsi-app--visible-entries valsi-app--entries root))
         (recognized (seq-remove
                      (lambda (entry)
                        (eq (plist-get entry :grammar) 'generic))
                      entries))
         (markdown (seq-filter
                    (lambda (entry)
                      (eq (plist-get entry :grammar) 'generic))
                    entries))
         (groups (valsi-app--group recognized))
         (attention (valsi-app--attention-entries entries))
         (agents (valsi-terminal-agent-list root))
         (layout (valsi-app--layout)))
    (setq valsi-app--last-layout layout)
    (erase-buffer)
    (valsi-app--insert-header root recognized markdown agents)
    (if valsi-app--compact
        (progn
          (valsi-app--insert-context layout)
          (insert "\n" (propertize "s hide · c hub · ? commands\n"
                                   'face 'valsi-state-face)))
      (valsi-app--insert-overview-section groups layout)
      (when attention
        (insert "\n")
        (valsi-app--insert-attention-section attention root layout))
      (valsi-app--insert-active-section entries agents root)
      (insert "\n")
      (valsi-app--insert-artifacts-section recognized groups root)
      (when (and valsi-app-show-generic-markdown markdown)
        (insert "\n")
        (valsi-app--insert-markdown-section markdown root))
      (when agents
        (insert "\n")
        (valsi-app--insert-agents-section agents layout))
      (insert "\n")
      (valsi-app--insert-project-section))))

(defun valsi-app--render ()
  "Render current Valsi application buffer without losing view position."
  (valsi-view-preserving-render #'valsi-app--render-contents))

(defvar valsi-app-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'valsi-app-refresh)
    (define-key map (kbd "RET") #'valsi-app-activate)
    (define-key map (kbd "/") #'valsi-app-filter)
    (define-key map (kbd "TAB") #'valsi-view-toggle-section)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "a") #'valsi-agent)
    (define-key map (kbd "@") #'valsi-app-handoff)
    (define-key map (kbd "f") #'project-find-file)
    (define-key map (kbd "D") #'project-dired)
    (define-key map (kbd "b") #'project-switch-to-buffer)
    (define-key map (kbd "T") #'valsi-app-project-tree)
    (dolist (key '("n" "p" "t" "l" "G" "%" "o" "d"))
      (define-key map (kbd key) #'valsi-app-context-command))
    (define-key map (kbd "i") #'valsi-app-edit-selected)
    (define-key map (kbd "SPC") #'valsi-app-menu)
    (define-key map (kbd "M-n") #'valsi-app-menu)
    (define-key map (kbd "s") #'valsi-app-hide-sidebar)
    (define-key map (kbd "c") #'valsi)
    (define-key map (kbd "?") #'valsi-app-menu)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `valsi-app-mode'.")

(define-derived-mode valsi-app-mode special-mode "Valsi-App"
  "Project-level application hub for Valsi artifacts."
  (setq-local revert-buffer-function
              (lambda (&rest _) (valsi-app-refresh)))
  (setq-local valsi-view-section-render-function #'valsi-app--render)
  (valsi-app--install-window-hooks)
  (add-hook 'kill-buffer-hook #'valsi-app--unsubscribe nil t))

(defun valsi-app--install-window-hooks ()
  "Install the global window hooks that keep Valsi chrome dependent."
  (unless valsi-app--resize-hook-installed
    (add-hook 'window-size-change-functions
              #'valsi-app--window-size-changed)
    (add-hook 'window-buffer-change-functions
              #'valsi-app--window-buffer-changed)
    (setq valsi-app--resize-hook-installed t)))

(defun valsi-app--remove-window-hooks-when-done ()
  "Drop the global window hooks once no Valsi application buffer remains.
Return non-nil when the hooks were removed."
  (unless (seq-some
           (lambda (buffer)
             (with-current-buffer buffer
               (or valsi-app--compact
                   valsi-app--command-rail
                   (bound-and-true-p valsi-artifact-minor-mode)
                   (derived-mode-p 'valsi-app-mode))))
           (buffer-list))
    (remove-hook 'window-size-change-functions
                 #'valsi-app--window-size-changed)
    (remove-hook 'window-buffer-change-functions
                 #'valsi-app--window-buffer-changed)
    (setq valsi-app--resize-hook-installed nil)
    t))

(defun valsi-app--chrome-buffer-p (buffer)
  "Return non-nil when BUFFER is Valsi chrome: a sidebar or command rail."
  (and (buffer-live-p buffer)
       (or (buffer-local-value 'valsi-app--compact buffer)
           (buffer-local-value 'valsi-app--command-rail buffer))))

(defun valsi-app--primary-buffer-p (buffer)
  "Return non-nil when BUFFER anchors chrome: an artifact, hub, or agent."
  (and (buffer-live-p buffer)
       (not (valsi-app--chrome-buffer-p buffer))
       (with-current-buffer buffer
         (or (bound-and-true-p valsi-artifact-minor-mode)
             (derived-mode-p 'valsi-app-mode)
             (bound-and-true-p valsi-terminal-agent-mode)))))

(defun valsi-app--displayed-artifact (windows)
  "Return the first artifact buffer shown in WINDOWS wanting a sidebar."
  (seq-some
   (lambda (window)
     (let ((buffer (window-buffer window)))
       (and (buffer-live-p buffer)
            (with-current-buffer buffer
              (and (bound-and-true-p valsi-artifact-minor-mode)
                   (not valsi-app--sidebar-dismissed)))
            buffer)))
   windows))

(defun valsi-app--sync-chrome (frame)
  "Reconcile Valsi chrome in FRAME with the primary buffers it displays.
This is the single invariant governing chrome: the sidebar is visible
exactly when an artifact buffer is displayed (automatic display on, not
manually dismissed, frame wide enough); no chrome survives without a
primary Valsi buffer.  Every entry and exit path — `find-file', hub,
outline, dashboards, agents, `q', buffer switches — converges here.
Return an artifact buffer whose sidebar must be shown, or nil."
  (let* ((windows (window-list frame 'nomini))
         (artifact (valsi-app--displayed-artifact windows))
         (sidebar (seq-find
                   (lambda (window)
                     (buffer-local-value 'valsi-app--compact
                                         (window-buffer window)))
                   windows))
         (primary (seq-some
                   (lambda (window)
                     (valsi-app--primary-buffer-p (window-buffer window)))
                   windows)))
    ;; Rails (and a sidebar orphaned of any primary) never outlive the
    ;; primary Valsi buffers; the sidebar additionally requires a displayed
    ;; artifact, so it hides for the hub, outline, and agent views.
    (dolist (window windows)
      (let ((buffer (window-buffer window)))
        (when (and (window-live-p window)
                   (buffer-live-p buffer)
                   (valsi-app--chrome-buffer-p buffer)
                   (if (buffer-local-value 'valsi-app--compact buffer)
                       (not artifact)
                     (not primary))
                   (> (length (window-list frame 'nomini)) 1))
          (delete-window window))))
    (and valsi-app-auto-sidebar
         artifact
         (not (window-live-p sidebar))
         (valsi-app--sidebar-width-for-frame (frame-width frame))
         artifact)))

(defun valsi-app--window-buffer-changed (frame)
  "Run the chrome invariant of `valsi-app--sync-chrome' for FRAME."
  (unless (or (valsi-app--remove-window-hooks-when-done)
              valsi-app--updating-sidebar)
    (let ((show (let ((valsi-app--updating-sidebar t))
                  (valsi-app--sync-chrome frame))))
      (when show
        (valsi-app-show-sidebar show)))))

(defun valsi-app--window-size-changed (frame)
  "Hide sidebars in FRAME that would make their source window unusable.
Remove itself from `window-size-change-functions' once no Valsi
application buffer remains."
  (unless (valsi-app--remove-window-hooks-when-done)
    (unless valsi-app--updating-sidebar
      (let ((valsi-app--updating-sidebar t))
        (dolist (window (window-list frame 'nomini))
          (when-let* ((buffer (window-buffer window))
                      ((buffer-live-p buffer))
                      (compact (buffer-local-value 'valsi-app--compact buffer))
                      (source (buffer-local-value
                               'valsi-app--source-buffer buffer))
                      (source-window (and (buffer-live-p source)
                                          (get-buffer-window source frame))))
            (when (< (window-body-width source-window)
                     valsi-app-minimum-source-width)
              (delete-window window)
              (message
               "Valsi sidebar hidden after resize; C-c n s restores it"))))))))

(defun valsi-app-activate ()
  "Activate the actionable row at point or toggle its section.
Only a button on the current line qualifies; RET never jumps to a
target belonging to a different row."
  (interactive)
  (let ((button (or (button-at (point))
                    (save-excursion
                      (beginning-of-line)
                      (let ((next (next-button (point) t)))
                        (and next
                             (<= (button-start next) (line-end-position))
                             next))))))
    (cond (button (button-activate button))
          ((get-text-property (line-beginning-position) 'valsi-section-id)
           (valsi-view-toggle-section))
          (t (user-error "No action on this row")))))

(defun valsi-app-edit-selected ()
  "Open the selected artifact and enter Insert when it has a Valsi grammar."
  (interactive)
  (if (and valsi-app--compact
           (buffer-live-p valsi-app--source-buffer))
      (let ((source valsi-app--source-buffer))
        (if-let* ((window (get-buffer-window source t)))
            (select-window window)
          (switch-to-buffer source))
        (when (bound-and-true-p valsi-artifact-minor-mode)
          (valsi-enter-insert)))
    (let ((file (valsi-app--artifact-file-at-point)))
      (valsi-app-hide-sidebars)
      (find-file file)
      (unless (bound-and-true-p valsi-artifact-minor-mode)
        (valsi--maybe-enable))
      (when (bound-and-true-p valsi-artifact-minor-mode)
        (valsi-enter-insert)))))

(transient-define-prefix valsi-app-menu ()
  "Valsi project hub command menu."
  [["View"
    ("g" "refresh" valsi-app-refresh)
    ("/" "filter" valsi-app-filter)
    ("i" "edit artifact" valsi-app-edit-selected)
    ("s" "hide sidebar" valsi-app-hide-sidebar)]
   ["Project"
    ("f" "find file" project-find-file)
    ("D" "Dired" project-dired)
    ("T" "tree" valsi-app-project-tree)
    ("b" "buffers" project-switch-to-buffer)]
   ["Agents"
    ("a" "agent terminal" valsi-agent)
    ("@" "hand off reference" valsi-app-handoff)]
   ["Session"
    ("c" "project hub" valsi)
    ("q" "back" quit-window)]])

(define-obsolete-function-alias 'valsi-app-help 'valsi-app-menu "1.1")

(defun valsi-app--unsubscribe ()
  "Stop live refresh for the current hub buffer."
  (when valsi-app--root
    (valsi-app-live-refresh-unsubscribe (current-buffer) valsi-app--root)))

(defun valsi-app--buffer (root compact &optional source)
  "Return a populated project buffer for ROOT.
Use compact rendering when COMPACT is non-nil.  SOURCE is the artifact buffer
whose contextual commands should be shown."
  (let ((buffer (get-buffer-create (valsi-app--buffer-name root compact))))
    (with-current-buffer buffer
      (valsi-app-mode)
      (setq valsi-app--root root
            valsi-app--compact compact
            valsi-app--source-buffer source
            default-directory root)
      (valsi-app-live-refresh-subscribe
       (current-buffer) root #'valsi-app-refresh)
      (valsi-app-refresh))
    buffer))

(defun valsi-app--sidebar-width-for-frame (frame-columns &optional force)
  "Return sidebar width for FRAME-COLUMNS, or nil when auto-hidden.
FORCE permits an explicit narrow-frame request."
  (let ((available (- frame-columns valsi-app-minimum-source-width 1))
        (preferred (if (floatp valsi-app-sidebar-width)
                       (round (* valsi-app-sidebar-width frame-columns))
                     valsi-app-sidebar-width)))
    (unless (or (< available 24)
                (and (not force)
                     (or (< frame-columns
                            valsi-app-sidebar-minimum-frame-width)
                         (< available 28))))
      (max 24 (min preferred available)))))

(define-derived-mode valsi-app-command-rail-mode special-mode "Valsi-Keys"
  "Mode for Valsi's non-content command chrome."
  (valsi-app--install-window-hooks)
  (setq-local valsi-app--command-rail t)
  (setq-local mode-line-format nil)
  (setq-local cursor-type nil))

(defun valsi-app--rail-hint (source key label command)
  "Return a rail line for KEY and LABEL when SOURCE really binds KEY to COMMAND.
Checked through `key-binding' in SOURCE, so a modal layer such as meow that
shadows Valsi's minor-mode maps makes the shadowed hint disappear instead of
lying about the key."
  (when (with-current-buffer source
          (eq (key-binding (kbd key)) command))
    (format "%-4s %s\n"
            (if (equal key "<escape>") "ESC" key)
            label)))

(defun valsi-app--rail-render-hints (source hints)
  "Insert the HINTS lines that hold in SOURCE, separating groups.
HINTS is a list of (KEY LABEL COMMAND) entries and `gap' group separators."
  (let ((gap nil) (any nil))
    (dolist (hint hints)
      (if (eq hint 'gap)
          (setq gap t)
        (when-let* ((line (apply #'valsi-app--rail-hint source hint)))
          (when (and gap any) (insert "\n"))
          (setq gap nil any t)
          (insert line))))))

(defcustom valsi-app-rail-hub-hints
  '(("n" "next" valsi-app-context-command)
    ("p" "previous" valsi-app-context-command)
    ("TAB" "fold" valsi-view-toggle-section)
    ("RET" "open" valsi-app-activate)
    ("i" "edit" valsi-app-edit-selected)
    ("g" "refresh" valsi-app-refresh)
    ("/" "filter" valsi-app-filter)
    gap
    ("a" "agent" valsi-agent)
    ("@" "reference" valsi-app-handoff)
    ("s" "hide context" valsi-app-hide-sidebar)
    ("q" "back" quit-window)
    gap
    ("SPC" "commands" valsi-app-menu)
    ("M-n" "commands" valsi-app-menu))
  "Command hints offered for the project hub.
A list of (KEY LABEL COMMAND) entries and `gap' group separators; hints
whose KEY does not resolve to COMMAND in the live buffer are omitted."
  :type '(repeat (choice (const gap)
                         (list (string :tag "Key")
                               (string :tag "Label")
                               function)))
  :group 'valsi-app)

(defcustom valsi-app-rail-browse-hints
  '(("n" "next" valsi-next)
    ("p" "previous" valsi-previous)
    ("TAB" "fold" valsi-browse-toggle-fold)
    ("RET" "follow" valsi-follow)
    ("i" "edit" valsi-enter-insert)
    ("g" "refresh" valsi-refresh)
    ("/" "search" isearch-forward)
    gap
    ("c" "hub" valsi)
    ("d" "outline" valsi-outline)
    ("a" "agent" valsi-agent)
    ("@" "reference" valsi-app-handoff)
    ("s" "context" valsi-app-toggle-sidebar)
    ("q" "back" quit-window)
    gap
    ("SPC" "commands" valsi-menu)
    ("M-n" "commands" valsi-menu))
  "Command hints offered for an artifact in the Browse state.
See `valsi-app-rail-hub-hints' for the format."
  :type '(repeat (choice (const gap)
                         (list (string :tag "Key")
                               (string :tag "Label")
                               function)))
  :group 'valsi-app)

(defcustom valsi-app-rail-insert-hints
  '(("<escape>" "browse" valsi-enter-browse)
    ("M-n" "commands" valsi-menu))
  "Command hints offered for an artifact in the Insert state.
See `valsi-app-rail-hub-hints' for the format."
  :type '(repeat (choice (const gap)
                         (list (string :tag "Key")
                               (string :tag "Label")
                               function)))
  :group 'valsi-app)

(defun valsi-app--render-command-rail (source)
  "Render commands appropriate to primary buffer SOURCE.
Every hint is validated against SOURCE's live keymaps."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Valsi KEYS\n\n" 'face 'bold))
    (cond
     ((eq (buffer-local-value 'major-mode source) 'valsi-app-mode)
      (valsi-app--rail-render-hints source valsi-app-rail-hub-hints))
     ((buffer-local-value 'valsi-artifact-minor-mode source)
      (if (eq (buffer-local-value 'valsi--interaction-state source) 'insert)
          (progn
            (insert "INSERT\n\n")
            (valsi-app--rail-render-hints source valsi-app-rail-insert-hints))
        (insert "BROWSE\n\n")
        (valsi-app--rail-render-hints source valsi-app-rail-browse-hints)))
     ((buffer-local-value 'valsi-terminal-agent-mode source)
      (insert "AGENT\n\n")
      (valsi-app--rail-render-hints
       source '(("M-n" "commands" valsi-terminal-agent-menu))))
     (t
      (insert "M-n  commands\n")))))

(defun valsi-app-show-command-rail (&optional source root)
  "Show command chrome for SOURCE when the current frame is wide enough.
Return nil without complaint when SOURCE belongs to no Emacs project, so
callers on the `find-file' path degrade instead of signaling."
  (when-let* ((valsi-app-auto-command-rail)
              ((>= (frame-width) valsi-app-command-rail-minimum-frame-width))
              (source (or source (current-buffer)))
              (root (or root
                        (with-current-buffer source
                          (ignore-errors (valsi-app--root))))))
    ;; `select-window' switches the current buffer; callers on the
    ;; `find-file-noselect' path depend on it staying untouched.
    (save-current-buffer
      (let* ((buffer
              (get-buffer-create (valsi-app--command-rail-buffer-name root)))
             (selected (selected-window)))
        (with-current-buffer buffer
          (valsi-app-command-rail-mode)
          (setq valsi-app--root root
                valsi-app--source-buffer source
                default-directory root)
          (valsi-app--render-command-rail source))
        (let ((window
               (display-buffer-in-side-window
                buffer
                `((side . ,valsi-app-sidebar-side)
                  (slot . 1)
                  (window-width . ,valsi-app-command-rail-width)))))
          (set-window-dedicated-p window t)
          (when (window-live-p selected)
            (select-window selected))
          window)))))

(defun valsi-app--open (compact)
  "Open current project hub; use COMPACT for artifact-index rendering."
  (let* ((root (valsi-app--root))
         (buffer (valsi-app--buffer root compact
                                   (and compact (current-buffer)))))
    (unless compact
      (valsi-app-hide-sidebars))
    (switch-to-buffer buffer)
    (unless compact
      (valsi-app-show-command-rail buffer root))
    buffer))

(defun valsi-app-show-sidebar (&optional source force)
  "Display the compact project overview beside artifact buffer SOURCE.
SOURCE defaults to the current buffer.  The source window remains selected.
When FORCE is non-nil, honor an explicit request even on a narrow frame."
  (interactive (list nil t))
  (unless valsi-app--updating-sidebar
    (let* ((valsi-app--updating-sidebar t)
           (source (or source (current-buffer)))
           (frame-columns (frame-width))
           (sidebar-width
            (valsi-app--sidebar-width-for-frame frame-columns force))
           (root (with-current-buffer source
                   (ignore-errors (valsi-app--root)))))
      (cond
       ((null root)                     ; no project: degrade, never signal
        (when (called-interactively-p 'interactive)
          (message "Valsi: no Emacs project detected here"))
        nil)
       ((null sidebar-width)
        (message "Valsi sidebar hidden at this width; C-c n s restores it")
        nil)
       (t
        ;; `select-window' switches the current buffer; callers on the
        ;; `find-file-noselect' path depend on it staying untouched.
        (save-current-buffer
          (let* ((buffer (valsi-app--buffer root t source))
                 (selected (selected-window))
                 (window
                  (display-buffer-in-side-window
                   buffer
                   `((side . ,valsi-app-sidebar-side)
                     (slot . 0)
                     (window-width . ,sidebar-width)))))
            (set-window-dedicated-p window t)
            (set-window-parameter window 'no-other-window nil)
            ;; The command rail may have fixed the shared side width first;
            ;; the sidebar's preferred width wins over the rail's.
            (let ((delta (- sidebar-width (window-body-width window))))
              (unless (zerop delta)
                (ignore-errors (window-resize window delta t t))))
            (when (window-live-p selected)
              (select-window selected))
            (valsi-app-show-command-rail source root)
            window)))))))

(defun valsi-app-hide-sidebar ()
  "Hide the compact artifact sidebar for the current project."
  (interactive)
  (when-let* ((root (valsi-app--root))
              (buffer (get-buffer (valsi-app--buffer-name root t)))
              (window (get-buffer-window buffer t)))
    (delete-window window)))

(defun valsi-app-hide-sidebars (&optional frame)
  "Delete every Valsi contextual sidebar in FRAME.
FRAME defaults to the selected frame. Primary windows are never deleted."
  (interactive)
  (let ((frame (or frame (selected-frame))))
    (dolist (window (window-list frame 'nomini))
      (let ((buffer (window-buffer window)))
        (when (and (buffer-live-p buffer)
                   (buffer-local-value 'valsi-app--compact buffer)
                   (> (length (window-list frame 'nomini)) 1))
          (delete-window window))))))

(defun valsi-app-toggle-sidebar ()
  "Toggle the compact artifact sidebar for the current project.
The choice is remembered for this artifact: a manually hidden sidebar is
not restored automatically."
  (interactive)
  (let* ((root (valsi-app--root))
         (buffer (get-buffer (valsi-app--buffer-name root t)))
         (window (and buffer (get-buffer-window buffer t))))
    (if (window-live-p window)
        (progn
          (setq valsi-app--sidebar-dismissed t)
          (delete-window window))
      (setq valsi-app--sidebar-dismissed nil)
      (valsi-app-show-sidebar (current-buffer) t))))

;;;###autoload
(defun valsi ()
  "Open the Magit-like Valsi artifact application for the current project."
  (interactive)
  (valsi-app--open nil))

;;;###autoload
(defun valsi-artifacts ()
  "Open the compact artifact index for the current project."
  (interactive)
  (valsi-app--open t))

(defun valsi-app-refresh ()
  "Reconcile and redraw the current project artifact view."
  (interactive)
  (unless valsi-app--root (user-error "This buffer has no Valsi project"))
  (setq valsi-app--entries
        (valsi-app-live-refresh-reconcile
         valsi-app--root (valsi-app--scan valsi-app--root)))
  (valsi-app--render))

(defun valsi-app-filter (query)
  "Filter artifact rows by family or path using QUERY.
An empty query clears the filter."
  (interactive
   (list (read-string "Artifact filter (empty clears): "
                      valsi-app--filter)))
  (setq valsi-app--filter
        (unless (string-empty-p query) (downcase query)))
  (valsi-app--render))

(defun valsi-app--artifact-file-at-point ()
  "Return the artifact file represented at point or by the current buffer."
  (let ((button (button-at (point))))
    (or (and button (button-get button 'valsi-file))
        (and button
             (when-let* ((entry (button-get button 'valsi-entry)))
               (plist-get entry :file)))
        (and valsi-app--compact
             (buffer-live-p valsi-app--source-buffer)
             (buffer-local-value 'buffer-file-name
                                 valsi-app--source-buffer))
        buffer-file-name
        (user-error "No artifact is selected at point"))))

(defun valsi-app--artifact-node-id ()
  "Return a stable semantic identifier for the artifact node at point."
  (let ((source (if (and valsi-app--compact
                         (buffer-live-p valsi-app--source-buffer))
                    valsi-app--source-buffer
                  (current-buffer))))
    (with-current-buffer source
      (when (and (bound-and-true-p valsi-artifact-minor-mode)
                 (fboundp 'valsi-tree))
        (when-let* ((node (valsi-node-at (valsi-tree) (point))))
          (let ((id (or (valsi-node-prop node :id)
                        (valsi-node-prop node :name)
                        (valsi-node-prop node :title))))
            (when id
              (format "%s:%s"
                      (symbol-name (valsi-node-type node)) id))))))))

;;;###autoload
(defun valsi-app-handoff ()
  "Insert the selected artifact reference into an agent without submitting."
  (interactive)
  (let* ((file (file-truename (valsi-app--artifact-file-at-point)))
         (node-id (valsi-app--artifact-node-id))
         (reference
          (if node-id
              (format "@%s from %s" node-id file)
            (format "@artifact:%s" file))))
    (valsi-terminal-agent-insert reference)
    (message "Inserted artifact reference; review it in the agent prompt")))

(defun valsi-app-project-tree ()
  "Open configured project tree, falling back to project Dired."
  (interactive)
  (if valsi-app-tree-function
      (call-interactively valsi-app-tree-function)
    (call-interactively #'project-dired)))

(defun valsi-app-focus-agent ()
  "Focus the current project's primary terminal agent."
  (interactive)
  (valsi-agent))

(defun valsi-app-focus-artifacts ()
  "Focus or open the current project's compact artifact index."
  (interactive)
  (let* ((root (valsi-terminal-agent-project-root))
         (buffer (get-buffer (valsi-app--buffer-name root t)))
         (window (and buffer (get-buffer-window buffer))))
    (if window
        (select-window window)
      (valsi-artifacts))))

(defun valsi-app-leave ()
  "Leave the current Valsi view through ordinary buffer history."
  (interactive)
  (valsi-app-hide-sidebars)
  (quit-window))

;;;###autoload
(defun valsi-agent-with-artifacts ()
  "Open the project agent without creating a split.
This compatibility command no longer creates the former composition layout."
  (interactive)
  (valsi-app-hide-sidebars)
  (valsi-agent))

(provide 'valsi-app)
;;; valsi-app.el ends here

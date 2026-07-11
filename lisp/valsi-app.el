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
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'valsi-registry)
(require 'valsi-app-live-refresh)
(require 'valsi-terminal-agent)

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

(defcustom valsi-app-tree-function nil
  "Optional command used by `valsi-app-project-tree'.
Nil falls back to `project-dired'."
  :type '(choice (const nil) function)
  :group 'valsi-app)

(defvar-local valsi-app--root nil)
(defvar-local valsi-app--entries nil)
(defvar-local valsi-app--compact nil)
(defvar-local valsi-app--filter nil)

(defvar valsi-app--saved-window-configurations (make-hash-table :test #'equal)
  "Project roots mapped to the window configuration before composition.")

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

(defun valsi-app--project-files (root)
  "Return Markdown project files below ROOT."
  (let* ((default-directory root)
         (project (project-current nil root)))
    (seq-filter
     (lambda (file)
       (and (string-match-p "\\.\\(?:md\\|mdc\\|markdown\\)\\'" file)
            (file-regular-p file)))
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
  "Return recognized artifact entries below ROOT."
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
            (unless (eq grammar 'generic)
              (push (list :file file :grammar grammar
                          :state (valsi-app--file-state file)
                          :summary (valsi-app--artifact-summary grammar text)
                          :warnings (plist-get diagnostics :warnings)
                          :stale (plist-get diagnostics :stale)
                          :mtime (file-attribute-modification-time
                                  (file-attributes file)))
                    entries)))
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
  (find-file (button-get button 'valsi-file)))

(defun valsi-app--family-button (button)
  "Open the family dashboard represented by BUTTON."
  (let* ((grammar (button-get button 'valsi-grammar))
         (entry (button-get button 'valsi-entry))
         (file (plist-get entry :file))
         (command (valsi-registry-command grammar 'dashboard)))
    (find-file file)
    (if (and command (commandp command))
        (call-interactively command)
      (message "Valsi: %s has no dedicated family dashboard" grammar))))

(defun valsi-app--agent-button (button)
  "Focus the terminal agent represented by BUTTON."
  (pop-to-buffer (button-get button 'valsi-buffer)))

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

(defun valsi-app--relevant-entries (entries)
  "Return the most relevant subset of ENTRIES for the project hub."
  (seq-take
   (sort (copy-sequence entries)
         (lambda (left right)
           (let ((left-state (plist-get left :state))
                 (right-state (plist-get right :state)))
             (if (equal (equal left-state "clean")
                        (equal right-state "clean"))
                 (time-less-p (or (plist-get right :mtime) '(0 0 0 0))
                              (or (plist-get left :mtime) '(0 0 0 0)))
               (not (equal left-state "clean"))))))
   valsi-app-relevant-limit))

(defun valsi-app--render ()
  "Render current Valsi application buffer."
  (let* ((inhibit-read-only t)
         (root valsi-app--root)
         (entries (valsi-app--visible-entries valsi-app--entries root))
         (groups (valsi-app--group entries)))
    (erase-buffer)
    (insert (propertize
             (format "Valsi · %s\n%s\n\n"
                     (valsi-app--project-name root) root)
             'face 'bold))
    (insert (propertize "Artifacts\n" 'face 'bold))
    (when valsi-app--filter
      (insert (format "Filter: %s\n" valsi-app--filter)))
    (if entries
        (dolist (grammar
                 (sort (hash-table-keys groups)
                       (lambda (a b)
                         (string< (symbol-name a) (symbol-name b)))))
          (let* ((items (nreverse (gethash grammar groups)))
                 (states (valsi-app--state-counts items))
                 (warnings (apply #'+ (mapcar
                                       (lambda (entry)
                                         (or (plist-get entry :warnings) 0))
                                       items)))
                 (stale (apply #'+ (mapcar
                                    (lambda (entry)
                                      (or (plist-get entry :stale) 0))
                                    items)))
                 (summary (delq nil
                                (list (and (not (string-empty-p states)) states)
                                      (and (> warnings 0)
                                           (format "%d warning%s" warnings
                                                   (if (= warnings 1) "" "s")))
                                      (and (> stale 0)
                                           (format "%d stale" stale))
                                      (seq-some
                                       (lambda (entry)
                                         (plist-get entry :summary))
                                       items)))))
            (insert-text-button
             (format "%-14s" (capitalize (symbol-name grammar)))
             'follow-link t
             'help-echo "Open dedicated family dashboard"
             'valsi-grammar grammar
             'valsi-entry (car items)
             'action #'valsi-app--family-button)
            (insert (format " %3d  %s\n"
                            (length items)
                            (if summary (string-join summary " · ") "clean")))))
      (insert "  No recognized project artifacts\n"))
    (insert "\n" (propertize "Relevant artifacts\n" 'face 'bold))
    (if entries
        (dolist (entry (valsi-app--relevant-entries entries))
          (valsi-app--insert-file entry root))
      (insert "  none\n"))
    (unless valsi-app--compact
      (insert "\n" (propertize "Agents\n" 'face 'bold))
      (let ((instances (valsi-terminal-agent-list root)))
        (if instances
            (dolist (instance instances)
              (let ((buffer (valsi-terminal-agent-instance-buffer instance)))
                (insert
                 (format "%-10s "
                         (if (and (buffer-live-p buffer)
                                  (process-live-p (get-buffer-process buffer)))
                             "running" "stopped")))
                (insert-text-button
                 (format "%-12s" (valsi-terminal-agent-instance-name instance))
                 'follow-link t
                 'valsi-buffer buffer
                 'action #'valsi-app--agent-button)
                (insert
                 (format " %-8s %-8s %s\n"
                         (valsi-terminal-agent-instance-backend instance)
                         (or (valsi-terminal-agent-instance-capability instance)
                             'unknown)
                         (or (valsi-terminal-agent-instance-task instance) "—")))))
          (insert "  none · a starts the primary agent\n")))
      (insert "\n" (propertize "Project\n" 'face 'bold))
      (insert "f find file · D project Dired · T tree · b project buffer\n"))
    (insert "\nRET open · @ handoff · / filter · g refresh")
    (unless valsi-app--compact
      (insert " · a agent · q quit"))
    (insert "\n")
    (goto-char (point-min))))

(defvar valsi-app-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'valsi-app-refresh)
    (define-key map (kbd "RET") #'push-button)
    (define-key map (kbd "/") #'valsi-app-filter)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "a") #'valsi-agent)
    (define-key map (kbd "@") #'valsi-app-handoff)
    (define-key map (kbd "f") #'project-find-file)
    (define-key map (kbd "D") #'project-dired)
    (define-key map (kbd "b") #'project-switch-to-buffer)
    (define-key map (kbd "T") #'valsi-app-project-tree)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `valsi-app-mode'.")

(define-derived-mode valsi-app-mode special-mode "Valsi-App"
  "Project-level application hub for Valsi artifacts."
  (setq-local revert-buffer-function
              (lambda (&rest _) (valsi-app-refresh)))
  (add-hook 'kill-buffer-hook #'valsi-app--unsubscribe nil t))

(defun valsi-app--unsubscribe ()
  "Stop live refresh for the current hub buffer."
  (when valsi-app--root
    (valsi-app-live-refresh-unsubscribe (current-buffer) valsi-app--root)))

(defun valsi-app--open (compact)
  "Open current project hub; use COMPACT for artifact-index rendering."
  (let* ((root (valsi-app--root))
         (buffer (get-buffer-create (valsi-app--buffer-name root compact))))
    (with-current-buffer buffer
      (valsi-app-mode)
      (setq valsi-app--root root
            valsi-app--compact compact
            default-directory root)
      (valsi-app-live-refresh-subscribe
       (current-buffer) root #'valsi-app-refresh)
      (valsi-app-refresh))
    (switch-to-buffer buffer)
    buffer))

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
        buffer-file-name
        (user-error "No artifact is selected at point"))))

(defun valsi-app--artifact-node-id ()
  "Return a stable semantic identifier for the artifact node at point."
  (when (and (bound-and-true-p valsi-artifact-minor-mode)
             (fboundp 'valsi-tree))
    (when-let* ((node (valsi-node-at (valsi-tree) (point))))
      (let ((id (or (valsi-node-prop node :id)
                    (valsi-node-prop node :name)
                    (valsi-node-prop node :title))))
        (when id
          (format "%s:%s" (symbol-name (valsi-node-type node)) id))))))

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
  "Leave a composed Valsi layout and restore its saved windows.
When no layout was composed, bury the current Valsi buffer normally."
  (interactive)
  (let* ((root (valsi-terminal-agent-project-root))
         (configuration (gethash root valsi-app--saved-window-configurations)))
    (if (and configuration
             (window-configuration-p configuration))
        (progn
          (remhash root valsi-app--saved-window-configurations)
          (set-window-configuration configuration))
      (quit-window))))

;;;###autoload
(defun valsi-agent-with-artifacts ()
  "Compose the project agent terminal with a compact artifact side window."
  (interactive)
  (let* ((root (valsi-terminal-agent-project-root))
         (before (current-window-configuration))
         (agent (valsi-agent))
         (agent-buffer (valsi-terminal-agent-instance-buffer agent))
         (index-buffer
          (save-window-excursion
            (let ((default-directory root))
              (valsi-app--open t)))))
    (unless (gethash root valsi-app--saved-window-configurations)
      (puthash root before valsi-app--saved-window-configurations))
    (delete-other-windows)
    (switch-to-buffer agent-buffer)
    (when (>= (window-total-width) 90)
      (let ((side (split-window-right
                   (max 55 (floor (* (window-total-width) 0.8))))))
        (set-window-buffer side index-buffer)))
    (select-window (get-buffer-window agent-buffer))))

(provide 'valsi-app)
;;; valsi-app.el ends here

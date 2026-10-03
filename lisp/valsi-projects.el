;;; valsi-projects.el --- Multiple-project overview and resume -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Projects is the navigation level above the existing artifact hubs.  It
;; shares their snapshots, keeps terminal processes intact, and restores each
;; project's windows independently in each frame.

;;; Code:

(require 'valsi-app)
(require 'valsi-project)

(declare-function valsi--maybe-enable "valsi")

(defvar-local valsi-projects--subscriptions nil "Roots observed by this overview.")
(defvar-local valsi-projects--unavailable nil "Roots not eligible for background scans.")
(defvar-local valsi-projects--layout nil "Last rendered responsive layout.")
(defvar-local valsi-projects--filter nil "Case-insensitive project path filter.")

(defun valsi-projects--save-layout ()
  "Remember the current project's windows in this frame."
  (unless (derived-mode-p 'valsi-projects-mode)
    (when-let* ((root (valsi-project-current-root)))
      (valsi-project-register root)
      (set-frame-parameter
       nil 'valsi-project-layouts
       (cons (cons root (list (window-state-get (frame-root-window))
                              (current-buffer) (point)))
             (assoc-delete-all root (frame-parameter nil 'valsi-project-layouts)))))))

(defun valsi-projects--main-window ()
  "Select a regular window before replacing the frame's project layout."
  (when (window-parameter (selected-window) 'window-side)
    (select-window
     (or (seq-find (lambda (window) (not (window-parameter window 'window-side)))
                   (window-list nil 'nomini))
         (selected-window)))))

;;;###autoload
(defun valsi-project-switch (root)
  "Resume project ROOT's windows, or open its hub on the first visit."
  (interactive
   (list
    (let* ((roots (valsi-project-roots))
           (choices (mapcar (lambda (root) (cons (valsi-project-label root) root)) roots)))
      (unless choices (user-error "No working projects; use M-x valsi-projects and +"))
      (cdr (assoc (completing-read "Switch project: " choices nil t) choices)))))
  (setq root (valsi-project-canonical-root root))
  (unless (file-directory-p root)
    (user-error "Project directory is unavailable: %s" root))
  (valsi-projects--save-layout)
  (valsi-project-register root)
  (let* ((saved (cdr (assoc root (frame-parameter nil 'valsi-project-layouts))))
         (source (nth 1 saved))
         (valsi-app--updating-sidebar t))
    (valsi-projects--main-window)
    (if (and saved (buffer-live-p source))
        (condition-case nil
            (progn
              (window-state-put (car saved) (frame-root-window) 'safe)
              (when-let* ((window (get-buffer-window source)))
                (select-window window)
                (goto-char (min (nth 2 saved) (point-max)))))
          (error (setq saved nil)))
      (setq saved nil))
    (unless saved
      (valsi-app-hide-sidebars)
      (delete-other-windows)
      (switch-to-buffer (valsi-app--buffer root nil)))
    (set-frame-parameter nil 'valsi-project-current root))
  (valsi-app--window-buffer-changed (selected-frame)))

(defun valsi-projects--selected-root ()
  "Return project represented by the current row, or signal a user error."
  (or (get-text-property (line-beginning-position) 'valsi-project-root)
      (user-error "Move to a project row first")))

(defun valsi-projects-open-hub ()
  "Open the hub for the project on the current row."
  (interactive)
  (let ((root (valsi-projects--selected-root)))
    (valsi-project-switch root)
    (let ((default-directory root)) (valsi))))

(defun valsi-projects-open-agent ()
  "Open or start the selected project's agent."
  (interactive)
  (let ((root (valsi-projects--selected-root)))
    (valsi-project-switch root)
    (let ((default-directory root)) (valsi-agent))))

(defun valsi-projects-new-agent ()
  "Start a named agent in the selected project."
  (interactive)
  (let ((root (valsi-projects--selected-root)))
    (valsi-project-switch root)
    (let ((default-directory root)) (call-interactively #'valsi-agent-new))))

(defun valsi-projects--visit-file (button)
  "Open the project artifact on BUTTON."
  (let ((root (button-get button 'valsi-root))
        (file (button-get button 'valsi-file)))
    (unless (file-exists-p file)
      (user-error "Artifact is missing: %s" file))
    (valsi-project-switch root)
    (find-file file)
    (valsi--maybe-enable)))

(defun valsi-projects--visit-agent (button)
  "Focus the existing terminal represented by BUTTON."
  (let ((root (button-get button 'valsi-root))
        (buffer (button-get button 'valsi-buffer)))
    (unless (buffer-live-p buffer)
      (user-error "Terminal is closed; use a to open an agent"))
    (valsi-project-switch root)
    (switch-to-buffer buffer)))

(defun valsi-projects-activate ()
  "Open the selected artifact or agent, or resume the selected project."
  (interactive)
  (if-let* ((button (valsi-app--button-on-line)))
      (button-activate button)
    (valsi-project-switch (valsi-projects--selected-root))))

(defun valsi-projects-next ()
  "Move to the next project or child row."
  (interactive)
  (let ((position (next-single-property-change
                   (line-end-position) 'valsi-row-id nil (point-max))))
    (goto-char position)
    (while (and (< (point) (point-max)) (not (get-text-property (point) 'valsi-row-id)))
      (forward-line 1))))

(defun valsi-projects-previous ()
  "Move to the previous project or child row."
  (interactive)
  (let* ((position (line-beginning-position))
         (current (get-text-property position 'valsi-row-id))
         row)
    (while (and (> position (point-min))
                (progn
                  (setq position (previous-single-property-change
                                  position 'valsi-row-id nil (point-min))
                        row (get-text-property position 'valsi-row-id))
                  (or (null row) (equal row current)))))
    (when (and row (not (equal row current)))
      (goto-char position))))

(defun valsi-projects-add (directory)
  "Add the project containing DIRECTORY to the remembered working set."
  (interactive (list (project-prompt-project-dir)))
  (let* ((project (project-current nil directory))
         (root (and project (project-root project))))
    (unless root (user-error "Directory is not inside an Emacs project: %s" directory))
    (valsi-project-remember root)
    (valsi-projects)))

(defun valsi-projects-remove ()
  "Forget the selected project without deleting files or closing buffers.
A project with a running agent must be stopped explicitly before removal."
  (interactive)
  (let ((root (valsi-projects--selected-root)))
    (when (seq-some #'valsi-terminal-agent--live-p (valsi-terminal-agent-list root))
      (user-error "Project has running agents; stop them explicitly before removal"))
    (valsi-project-forget root)))

(defun valsi-projects-filter (query)
  "Filter project names and paths by QUERY; empty QUERY shows all."
  (interactive (list (read-string "Project filter (empty clears): " valsi-projects--filter)))
  (setq valsi-projects--filter (unless (string-empty-p query) (downcase query)))
  (valsi-projects--render))

(defun valsi-projects--unsubscribe ()
  "Release only this overview's project subscriptions."
  (dolist (root valsi-projects--subscriptions)
    (valsi-app-live-refresh-unsubscribe (current-buffer) root))
  (setq valsi-projects--subscriptions nil)
  (remove-hook 'window-size-change-functions #'valsi-projects--resized))

(defun valsi-projects--sync (&optional refresh)
  "Synchronize working-set subscriptions; REFRESH also reconciles existing roots."
  (let ((roots (valsi-project-roots)))
    (dolist (root (seq-difference valsi-projects--subscriptions roots #'equal))
      (valsi-app-live-refresh-unsubscribe (current-buffer) root)
      (setq valsi-projects--subscriptions (delete root valsi-projects--subscriptions)))
    (setq valsi-projects--unavailable nil)
    (dolist (root roots)
      (cond
       ((or (file-remote-p root) (not (file-directory-p root)))
        (push (cons root (if (file-remote-p root) "Remote · open to refresh"
                           "Directory unavailable")) valsi-projects--unavailable)
        (when (member root valsi-projects--subscriptions)
          (valsi-app-live-refresh-unsubscribe (current-buffer) root)
          (setq valsi-projects--subscriptions (delete root valsi-projects--subscriptions))))
       (t
        (let ((new (not (member root valsi-projects--subscriptions))))
          (when new
            (push root valsi-projects--subscriptions)
            (valsi-app-live-refresh-subscribe
             (current-buffer) root #'valsi-projects--render #'valsi-app--scan-project-steps))
          (let ((project (valsi-app-live-refresh--project root)))
            (when (or refresh
                      (and new (not (valsi-app-live-refresh--project-timer project))
                           (not (valsi-app-live-refresh--project-iterator project))))
              (valsi-app-live-refresh-schedule root nil t)))))))
    (valsi-projects--render)))

(defun valsi-projects-refresh ()
  "Refresh all working projects while retaining their last complete rows."
  (interactive)
  (valsi-projects--sync t))

(defun valsi-projects--changed ()
  "Update an existing overview after project membership changes."
  (when-let* ((buffer (get-buffer "*Valsi Projects*")))
    (with-current-buffer buffer (valsi-projects--sync))))

(defun valsi-projects--insert-project (root)
  "Insert project ROOT with its shared artifact and terminal state."
  (let* ((project (gethash root valsi-app-live-refresh--projects))
         (entries (and project (valsi-app-live-refresh--project-snapshot project)))
         (recognized (seq-remove (lambda (entry) (eq (plist-get entry :grammar) 'generic)) entries))
         (attention (valsi-app--attention-entries entries))
         (agents (valsi-terminal-agent-list root))
         (running (seq-count #'valsi-terminal-agent--live-p agents))
         (agent-attention (seq-count #'valsi-terminal-agent-attention-p agents))
         (status (and project (valsi-app-live-refresh--project-status project)))
         (unavailable (cdr (assoc root valsi-projects--unavailable)))
         (start (point)))
    (valsi-view-insert-section
     root (valsi-app--project-name root)
     (lambda ()
       (cond
        (unavailable (insert "  " (propertize unavailable 'face 'valsi-attention-face) "\n"))
        ((eq status 'refreshing) (insert "  Refreshing artifacts…\n"))
        ((stringp status) (insert "  " (propertize status 'face 'valsi-attention-face) " · g retries\n")))
       (dolist (entry attention)
         (let ((row (point)) (file (plist-get entry :file)))
           (insert "  ")
           (insert-text-button (concat (valsi-app--attention-reason entry) " · " (file-relative-name file root))
                               'face 'valsi-attention-face 'follow-link t
                               'valsi-root root 'valsi-file file 'action #'valsi-projects--visit-file)
           (insert "\n")
           (add-text-properties row (point) `(valsi-row-id ,(concat "attention:" file)))))
       (dolist (instance agents)
         (let ((row (point)))
           (insert "  ")
           (insert-text-button (valsi-terminal-agent-instance-name instance)
                               'follow-link t 'valsi-root root
                               'valsi-buffer (valsi-terminal-agent-instance-buffer instance)
                               'action #'valsi-projects--visit-agent)
           (insert " · " (propertize (valsi-terminal-agent-status-label instance)
                                      'face (if (valsi-terminal-agent-attention-p instance)
                                                'valsi-attention-face 'valsi-state-face))
                   " · " (symbol-name (valsi-terminal-agent-instance-backend instance)))
           (when-let* (((valsi-terminal-agent--live-p instance))
                       (detail (valsi-terminal-agent-instance-detail instance)))
             (insert " · " detail))
           (when-let* ((task (valsi-terminal-agent-instance-task instance)))
             (insert " · " task))
           (insert "\n")
           (add-text-properties row (point)
                                `(valsi-row-id ,(format "agent:%s:%s" root (valsi-terminal-agent-instance-name instance)))))))
     (let ((counts
            (format "%s · %d attention · %d running%s%s"
                    (if (and project (valsi-app-live-refresh--project-initialized project))
                        (format "%d artifacts" (length recognized)) "artifacts pending")
                    (+ (length attention) agent-attention) running
                    (if (> (length agents) running)
                        (format " · %d stopped" (- (length agents) running)) "")
                    (cond (unavailable " · unavailable")
                          ((eq status 'refreshing) " · refreshing")
                          ((stringp status) " · scan failed") (t "")))))
       (if (eq (valsi-app--layout) 'narrow)
           (concat "\n  " (valsi-project-label root) "\n  " counts)
         (concat counts "\n  " (valsi-project-label root))))
     t)
    (add-text-properties start (point) `(valsi-project-root ,root))
    (insert "\n")))

(defun valsi-projects--render-contents ()
  "Insert the working-project overview."
  (let* ((roots (valsi-project-roots))
         (visible (seq-filter (lambda (root)
                                (or (null valsi-projects--filter)
                                    (string-match-p (regexp-quote valsi-projects--filter) (downcase root)))) roots)))
    (setq valsi-projects--layout (valsi-app--layout))
    (erase-buffer)
    (insert (propertize "Valsi  Projects\n" 'face 'bold)
            (propertize (format "%d working projects\n\n" (length roots)) 'face 'valsi-state-face))
    (when valsi-project--load-error
      (insert (propertize (concat "Project declarations: " valsi-project--load-error "\n\n") 'face 'valsi-attention-face)))
    (when valsi-projects--filter (insert "Filter: " valsi-projects--filter "\n\n"))
    (cond
     ((null roots) (insert "No working projects yet.  + adds an Emacs project.\n\n"))
     ((null visible) (insert "No matching projects.  / clears the filter.\n\n"))
     (t (mapc #'valsi-projects--insert-project visible)))
    (insert (propertize "RET resume/open · TAB fold · c hub · a agent\n+ add · - remove · w switch · g refresh · / filter · ? commands · q back\n" 'face 'valsi-state-face))))

(defun valsi-projects--render ()
  "Redraw project rows without changing selection or window position."
  (valsi-view-preserving-render #'valsi-projects--render-contents)
  (set-buffer-modified-p nil))

(defun valsi-projects--resized (frame)
  "Adapt a visible overview to its width in FRAME."
  (when-let* ((buffer (get-buffer "*Valsi Projects*"))
              (window (get-buffer-window buffer frame)))
    (with-current-buffer buffer
      (unless (eq valsi-projects--layout (valsi-app--layout (window-body-width window)))
        (valsi-projects--render)))))

(defun valsi-projects-quit ()
  "Return to the window layout from which Projects was opened."
  (interactive)
  (if-let* ((state (frame-parameter nil 'valsi-projects-origin)))
      (progn
        (window-state-put state (frame-root-window) 'safe)
        ;; Emacs 29 restores the selected window without making its
        ;; buffer current.
        (select-window (frame-selected-window))
        (set-frame-parameter nil 'valsi-projects-origin nil))
    (quit-window)))

(transient-define-prefix valsi-projects-menu ()
  "Working-project commands."
  [["Navigate"
    ("RET" "resume/open" valsi-projects-activate)
    ("c" "project hub" valsi-projects-open-hub)
    ("a" "agent terminal" valsi-projects-open-agent)
    ("N" "new named agent" valsi-projects-new-agent)
    ("w" "switch project" valsi-project-switch)]
   ["Projects"
    ("+" "add" valsi-projects-add)
    ("-" "remove" valsi-projects-remove)
    ("g" "refresh" valsi-projects-refresh)
    ("/" "filter" valsi-projects-filter)]
   ["View"
    ("TAB" "fold" valsi-view-toggle-section)
    ("q" "back" valsi-projects-quit)]])

(defvar valsi-projects-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (binding '(("n" . valsi-projects-next) ("p" . valsi-projects-previous)
                       ("RET" . valsi-projects-activate) ("TAB" . valsi-view-toggle-section)
                       ("c" . valsi-projects-open-hub) ("a" . valsi-projects-open-agent)
                       ("N" . valsi-projects-new-agent) ("+" . valsi-projects-add) ("-" . valsi-projects-remove)
                       ("g" . valsi-projects-refresh) ("/" . valsi-projects-filter)
                       ("w" . valsi-project-switch) ("P" . valsi-projects)
                       ("?" . valsi-projects-menu) ("SPC" . valsi-projects-menu)
                       ("M-n" . valsi-projects-menu) ("q" . valsi-projects-quit)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map)
  "Keymap for the working-project overview.")

(define-derived-mode valsi-projects-mode special-mode "Valsi-Projects"
  "Overview of working projects, their artifacts and terminal agents."
  (setq-local valsi-view-section-render-function #'valsi-projects--render)
  (setq-local revert-buffer-function (lambda (&rest _) (valsi-projects-refresh)))
  (add-hook 'kill-buffer-hook #'valsi-projects--unsubscribe nil t)
  (add-hook 'window-size-change-functions #'valsi-projects--resized))

;;;###autoload
(defun valsi-projects ()
  "Show working projects and their artifact and agent attention."
  (interactive)
  (unless (derived-mode-p 'valsi-projects-mode)
    (valsi-projects--save-layout)
    (set-frame-parameter nil 'valsi-projects-origin (window-state-get (frame-root-window))))
  (let ((buffer (get-buffer-create "*Valsi Projects*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'valsi-projects-mode) (valsi-projects-mode))
      (valsi-projects--sync))
    (valsi-projects--main-window)
    (valsi-app-hide-sidebars)
    (delete-other-windows)
    (switch-to-buffer buffer)))

(add-hook 'valsi-project-change-hook #'valsi-projects--changed)

(defun valsi-projects--agents-changed ()
  "Redraw the overview after an agent status update."
  (when-let* ((buffer (get-buffer "*Valsi Projects*")))
    (with-current-buffer buffer (valsi-projects--render))))

(add-hook 'valsi-terminal-agent-change-hook #'valsi-projects--agents-changed)

(provide 'valsi-projects)
;;; valsi-projects.el ends here

;;; valsi-plan-agent.el --- Send plan tasks to terminal agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Plan artifacts assemble useful context for a real coding-agent CLI.  Valsi
;; pastes that context into the CLI's Eat terminal without submitting it.  The
;; CLI keeps ownership of tools, permissions, authentication, and sessions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-plan)
(require 'valsi-plan-review)
(require 'valsi-terminal-agent)

(defun valsi-plan--task-group-title (root task)
  "Return the title of the nearest heading group preceding TASK in ROOT."
  (let ((best nil)
        (task-beg (valsi-node-beg task)))
    (dolist (group (valsi-node-of-type root 'group))
      (when (and (< (valsi-node-beg group) task-beg)
                 (or (null best)
                     (> (valsi-node-beg group) (valsi-node-beg best))))
        (setq best group)))
    (and best (valsi-node-prop best :title))))

(defun valsi-plan--task-files (task)
  "Return manifest file paths referenced by TASK and its metadata."
  (let ((refs (copy-sequence (valsi-node-prop task :pathrefs))))
    (dolist (meta (valsi-node-of-type task 'meta))
      (setq refs
            (append refs
                    (valsi-parse-pathrefs (valsi-node-prop meta :text "")))))
    (delete-dups
     (mapcar (lambda (path) (car (split-string path ":"))) refs))))

(defun valsi-plan--task-verify (task)
  "Return the concatenated text of TASK's Verify metadata."
  (string-join
   (delq nil
         (mapcar
          (lambda (meta)
            (and (eq (valsi-node-prop meta :label) 'verify)
                 (valsi-node-prop meta :text)))
          (valsi-node-of-type task 'meta)))
   "\n"))

(defun valsi-plan--verify-command (task)
  "Return the first backtick command in TASK's Verify metadata."
  (let ((verification (valsi-plan--task-verify task)))
    (when (string-match "`\\([^`\n]+\\)`" verification)
      (match-string 1 verification))))

(defun valsi-plan-context-bundle (root task)
  "Return the agent context bundle plist for TASK in ROOT."
  (list :id (valsi-node-prop task :id)
        :desc (valsi-node-prop task :desc)
        :state (valsi-plan-effective-state task)
        :group (valsi-plan--task-group-title root task)
        :files (valsi-plan--task-files task)
        :deps (valsi-node-prop task :deps)
        :traces (valsi-node-prop task :traces)
        :steps (mapcar (lambda (step) (valsi-node-prop step :text))
                       (valsi-node-of-type task 'step))
        :verify (valsi-plan--task-verify task)))

(defun valsi-plan-bundle->prompt (bundle)
  "Render context BUNDLE into a task prompt."
  (string-join
   (delq nil
         (list
          (format "Implement task %s: %s"
                  (or (plist-get bundle :id) "?")
                  (plist-get bundle :desc))
          (when (plist-get bundle :group)
            (format "Group: %s" (plist-get bundle :group)))
          (when (plist-get bundle :deps)
            (format "Depends on: %s"
                    (string-join (plist-get bundle :deps) ", ")))
          (when (plist-get bundle :files)
            (format "Files: %s"
                    (string-join (plist-get bundle :files) ", ")))
          (when (plist-get bundle :traces)
            (format "Requirements: %s"
                    (string-join (plist-get bundle :traces) ", ")))
          (when (plist-get bundle :steps)
            (format "Steps:\n%s"
                    (mapconcat (lambda (step) (concat "  - " step))
                               (plist-get bundle :steps) "\n")))
          (let ((verification (plist-get bundle :verify)))
            (when (and verification (not (string-empty-p verification)))
              (format "Verification: %s" verification)))))
   "\n"))

(defun valsi-plan--terminal-prompt (root task)
  "Return a review-before-submit terminal prompt for TASK in ROOT."
  (let* ((bundle (valsi-plan-context-bundle root task))
         (id (plist-get bundle :id))
         (source (and buffer-file-name (file-truename buffer-file-name))))
    (string-join
     (delq nil
           (list
            (valsi-plan-bundle->prompt bundle)
            (and source
                 (format "Task source: @task:%s from %s" (or id "?") source))
            (concat
             "The listed files are context hints, not a permission boundary; "
             "inspect other project files when needed.")))
     "\n\n")))

(defun valsi-plan-dispatch-task ()
  "Paste the task at point into a terminal agent without submitting it."
  (interactive)
  (let* ((root (valsi-plan--buffer-tree))
         (task (valsi-plan--task-at-line (valsi-node-of-type root 'task))))
    (unless task
      (user-error "No task on this line"))
    (valsi-terminal-agent-insert (valsi-plan--terminal-prompt root task))
    (message "Prepared %s in the agent prompt; review and submit there"
             (or (valsi-node-prop task :id) "task"))))

(defun valsi-plan-dispatch-next ()
  "Jump to the next actionable task and prepare it in the terminal agent."
  (interactive)
  (when (valsi-plan-next-actionable)
    (valsi-plan-dispatch-task)))

(defun valsi-plan-run-verification ()
  "Run the verification command for the task at point in `compilation-mode'."
  (interactive)
  (let* ((root (valsi-plan--buffer-tree))
         (task (valsi-plan--task-at-line (valsi-node-of-type root 'task)))
         (command (and task (valsi-plan--verify-command task))))
    (if command
        (compile command)
      (message "No verification command for this task"))))

(defun valsi-plan-complete-with-verification ()
  "Run task verification and mark it done only when the command succeeds."
  (interactive)
  (let* ((root (valsi-plan--buffer-tree))
         (task (valsi-plan--task-at-line (valsi-node-of-type root 'task)))
         (command (and task (valsi-plan--verify-command task))))
    (unless task
      (user-error "No task on this line"))
    (if (null command)
        (message "No verification command; use `valsi-plan-toggle' to mark done")
      (let ((code (call-process-shell-command command nil "*valsi-verify*")))
        (if (zerop code)
            (save-excursion
              (beginning-of-line)
              (when (looking-at valsi-parse-checkbox-re)
                (replace-match "x" t t nil 2))
              (message "Verified %s -> done"
                       (or (valsi-node-prop task :id) "task")))
          (when (y-or-n-p "Verification failed; block this task? ")
            (valsi-plan-block)))))))

(defun valsi-plan-distill-done (content ids)
  "Return a node diff marking each ID in IDS done in plan CONTENT."
  (let ((root (valsi-plan-parse content))
        changes)
    (dolist (task (valsi-node-of-type root 'task))
      (let ((id (valsi-node-prop task :id)))
        (when (and id (member id ids)
                   (not (eq (valsi-node-prop task :state) 'done)))
          (let* ((old (valsi-plan-review--slice-line content task))
                 (new (replace-regexp-in-string
                       "\\`\\([ \t]*-[ \t]+\\)\\[.\\]" "\\1[x]" old)))
            (push (list :kind 'modified :id id :old old :new new)
                  changes)))))
    (nreverse changes)))

(defun valsi-plan-distill ()
  "Open explicit plan node review.
Terminal agents own their transcripts, so Valsi does not scrape inferred task
outcomes from terminal contents."
  (interactive)
  (call-interactively #'valsi-plan-review-update))

(provide 'valsi-plan-agent)
;;; valsi-plan-agent.el ends here

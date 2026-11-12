;;; valsi-plan-agent.el --- Send plan tasks to terminal agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Plan artifacts assemble useful context for a real coding-agent CLI.  Valsi
;; pastes that context into the CLI's Eat terminal without submitting it.  The
;; CLI keeps ownership of tools, permissions, authentication, and sessions.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'subr-x)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-plan)
(require 'valsi-plan-review)
(require 'valsi-terminal-agent)

(declare-function valsi--call-browse-editable "valsi" (fn))

(defvar-local valsi-plan--verification nil
  "Pending completion as (PROCESS TASK-MARKER ORIGINAL-SUBTREE).")

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

(defun valsi-plan--own-nodes (task type)
  "Return TASK's descendants of TYPE, not descending into nested tasks.
A child task's steps and metadata belong to that child's own context."
  (let (out)
    (cl-labels ((walk (node)
                  (dolist (child (valsi-node-children node))
                    (unless (eq (valsi-node-type child) 'task)
                      (when (eq (valsi-node-type child) type)
                        (push child out))
                      (walk child)))))
      (walk task))
    (nreverse out)))

(defun valsi-plan--task-files (task)
  "Return manifest file paths referenced by TASK and its metadata."
  (let ((refs (copy-sequence (valsi-node-prop task :pathrefs))))
    (dolist (meta (valsi-plan--own-nodes task 'meta))
      (setq refs
            (append refs
                    (valsi-parse-pathrefs (valsi-node-prop meta :text "")))))
    (delete-dups (delq nil (mapcar #'valsi-plan--pathref-file refs)))))

(defun valsi-plan--meta-body (text)
  "Return meta line TEXT without its bold label, trimmed."
  (string-trim
   (if (string-match valsi-parse-meta-re text)
       (substring text (match-end 0))
     text)))

(defun valsi-plan--task-verify (task)
  "Return the concatenated text of TASK's Verify metadata.
The `**Verify:**' label itself is dropped; only its body is kept."
  (string-join
   (delq nil
         (mapcar
          (lambda (meta)
            (and (eq (valsi-node-prop meta :label) 'verify)
                 (valsi-plan--meta-body (valsi-node-prop meta :text ""))))
          (valsi-plan--own-nodes task 'meta)))
   "\n"))

(defun valsi-plan--verify-command (task)
  "Return the first backtick command in TASK's Verify metadata."
  (let ((verification (valsi-plan--task-verify task)))
    (when (string-match "`\\([^`\n]+\\)`" verification)
      (match-string 1 verification))))

(defun valsi-plan-context-bundle (root task)
  "Return the agent context bundle plist for TASK in ROOT."
  (list :id (valsi-node-prop task :id)
        :desc (let ((desc (valsi-node-prop task :desc)))
                ;; The id has its own field; keep tags, drop the id token.
                (if (and desc (valsi-node-prop task :id)
                         (string-match valsi-plan--leading-id-re desc))
                    (concat (match-string 1 desc)
                            (substring desc (match-end 0)))
                  desc))
        :state (valsi-plan-effective-state task)
        :group (valsi-plan--task-group-title root task)
        :files (valsi-plan--task-files task)
        :deps (valsi-node-prop task :deps)
        :traces (valsi-node-prop task :traces)
        :steps (mapcar (lambda (step) (valsi-node-prop step :text))
                       (valsi-plan--own-nodes task 'step))
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

(defun valsi-plan--clear-verification ()
  "Release the source marker held by this verification buffer."
  (when valsi-plan--verification
    (set-marker (nth 1 valsi-plan--verification) nil)
    (setq valsi-plan--verification nil)))

(defun valsi-plan--complete-verified-task (marker original)
  "Mark the task at MARKER done if its subtree still equals ORIGINAL."
  (with-current-buffer (marker-buffer marker)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char marker)
        (let* ((root (valsi-plan--buffer-tree))
               (task (valsi-plan--task-at-line (valsi-node-of-type root 'task)))
               (region (and task (valsi-plan--task-region task))))
          (if (not (and region (= (car region) (point))
                        (equal original (buffer-substring-no-properties
                                         (car region) (cdr region)))))
              (message "Verification passed; task changed, verify again")
            (let ((edit (lambda ()
                          (when (looking-at valsi-parse-checkbox-re)
                            (replace-match "x" t t nil 2)))))
              (if (fboundp 'valsi--call-browse-editable)
                  (valsi--call-browse-editable edit)
                (funcall edit))
              (message "Verified %s -> done"
                       (or (valsi-node-prop task :id) "task")))))))))

(defun valsi-plan--finish-verification (buffer _status)
  "Complete BUFFER's original task after a successful verification process.
Ignore the human-readable _STATUS; use the recorded process's exit status."
  (with-current-buffer buffer
    (when-let* ((pending valsi-plan--verification))
      (pcase-let ((`(,process ,marker ,original) pending))
        ;; A later `recompile' must not complete a task a second time.
        (setq valsi-plan--verification nil)
        (unwind-protect
            (cond
             ((not (and (eq (process-status process) 'exit)
                        (zerop (process-exit-status process))))
              (message "Verification failed; task unchanged (see %s)"
                       (buffer-name buffer)))
             ((not (marker-buffer marker))
              (message "Verification passed; source buffer was closed"))
             (t
              (condition-case err
                  (valsi-plan--complete-verified-task marker original)
                (error
                 (message "Verification passed; task unchanged: %s"
                          (error-message-string err))))))
          (set-marker marker nil))))))

(defun valsi-plan--start-verification (complete)
  "Review and asynchronously run the current task's verification command.
When COMPLETE is non-nil, mark the unchanged task done on success."
  (save-restriction
    (widen)
    (let* ((root (valsi-plan--buffer-tree))
           (task (valsi-plan--task-at-line (valsi-node-of-type root 'task)))
           (command (and task (valsi-plan--verify-command task))))
      (unless task (user-error "No task on this line"))
      (if (null command)
          (message "No verification command; use `valsi-plan-toggle' to mark done")
        (let* ((default-directory
                (or (valsi-project-current-root)
                    (and buffer-file-name (file-name-directory buffer-file-name))
                    default-directory))
               (region (valsi-plan--task-region task))
               (original (buffer-substring-no-properties (car region) (cdr region)))
               (command (read-shell-command
                         (format "Verify in %s: " (abbreviate-file-name default-directory))
                         command))
               (name (generate-new-buffer-name
                      (format "*valsi-verify: %s*"
                              (or (valsi-node-prop task :id) (buffer-name)))))
               marker started)
          (when (string-blank-p command)
            (user-error "Empty verification command"))
          (setq marker (and complete (copy-marker (car region) t)))
          (unwind-protect
              (let ((compilation-buffer-name-function (lambda (_) name))
                    (compilation-start-hook
                     (cons
                      (lambda (process)
                        (when complete
                          (with-current-buffer (process-buffer process)
                            (setq valsi-plan--verification
                                  (list process marker original))
                            (add-hook 'compilation-finish-functions
                                      #'valsi-plan--finish-verification nil t)
                            (add-hook 'kill-buffer-hook
                                      #'valsi-plan--clear-verification nil t))))
                      compilation-start-hook)))
                (prog1 (compile command)
                  (setq started t)))
            (when (and marker (not started)) (set-marker marker nil))))))))

(defun valsi-plan-run-verification ()
  "Review and run the task's command asynchronously from the project root."
  (interactive)
  (valsi-plan--start-verification nil))

(defun valsi-plan-complete-with-verification ()
  "Review and run verification; complete the unchanged task only on success.
Output appears in `compilation-mode'.  Failure leaves the task unchanged."
  (interactive)
  (valsi-plan--start-verification t))

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

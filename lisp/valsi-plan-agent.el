;;; valsi-plan-agent.el --- Wire the plan grammar to the agent core -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The payoff (Sprint 7): the flagship grammar assembles a context bundle for a
;; task, scopes the agent to the task's manifest files, dispatches, runs the
;; task's verification, and lands the agent's plan edits as a reviewable
;; node-diff (`valsi-plan-review').  This is the client-side, grammar-app tier
;; (tau's `tau_coding') that calls *into* the artifact-agnostic agent core.

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-plan)
(require 'valsi-plan-review)
(require 'valsi-agent)

(declare-function valsi-tree "valsi")

;;;; Context bundle (T701)

(defun valsi-plan--task-group-title (root task)
  "Return the title of the nearest heading group preceding TASK in ROOT."
  (let ((best nil) (tb (valsi-node-beg task)))
    (dolist (g (valsi-node-of-type root 'group))
      (when (and (< (valsi-node-beg g) tb)
                 (or (null best) (> (valsi-node-beg g) (valsi-node-beg best))))
        (setq best g)))
    (and best (valsi-node-prop best :title))))

(defun valsi-plan--task-files (task)
  "Return the manifest file paths referenced by TASK (own + meta path-refs)."
  (let ((refs (copy-sequence (valsi-node-prop task :pathrefs))))
    (dolist (m (valsi-node-of-type task 'meta))
      (setq refs (append refs (valsi-parse-pathrefs (valsi-node-prop m :text "")))))
    (delete-dups (mapcar (lambda (p) (car (split-string p ":"))) refs))))

(defun valsi-plan--task-verify (task)
  "Return the concatenated text of TASK's Verify meta lines."
  (string-join
   (delq nil (mapcar (lambda (m) (and (eq (valsi-node-prop m :label) 'verify)
                                      (valsi-node-prop m :text)))
                     (valsi-node-of-type task 'meta)))
   "\n"))

(defun valsi-plan--verify-command (task)
  "Return the first backtick command in TASK's Verify meta, or nil."
  (let ((v (valsi-plan--task-verify task)))
    (when (string-match "`\\([^`\n]+\\)`" v)
      (match-string 1 v))))

(defun valsi-plan-context-bundle (root task)
  "Return the agent context bundle plist for TASK in ROOT."
  (list :id (valsi-node-prop task :id)
        :desc (valsi-node-prop task :desc)
        :state (valsi-plan-effective-state task)
        :group (valsi-plan--task-group-title root task)
        :files (valsi-plan--task-files task)
        :deps (valsi-node-prop task :deps)
        :traces (valsi-node-prop task :traces)
        :steps (mapcar (lambda (s) (valsi-node-prop s :text))
                       (valsi-node-of-type task 'step))
        :verify (valsi-plan--task-verify task)))

(defun valsi-plan-bundle->prompt (bundle)
  "Render context BUNDLE into a task-dispatch prompt string."
  (string-join
   (delq nil
         (list
          (format "Implement task %s: %s"
                  (or (plist-get bundle :id) "?") (plist-get bundle :desc))
          (when (plist-get bundle :group)
            (format "Group: %s" (plist-get bundle :group)))
          (when (plist-get bundle :deps)
            (format "Depends on: %s" (string-join (plist-get bundle :deps) ", ")))
          (when (plist-get bundle :files)
            (format "Files: %s" (string-join (plist-get bundle :files) ", ")))
          (when (plist-get bundle :traces)
            (format "Requirements: %s" (string-join (plist-get bundle :traces) ", ")))
          (when (plist-get bundle :steps)
            (format "Steps:\n%s"
                    (mapconcat (lambda (s) (concat "  - " s))
                               (plist-get bundle :steps) "\n")))
          (let ((v (plist-get bundle :verify)))
            (when (and v (not (string-empty-p v)))
              (format "Verification: %s" v)))))
   "\n"))

;;;; Dispatch (T701, T704)

(defvar valsi-plan-agent-provider nil
  "Provider for plan dispatch; nil constructs an anthropic-oauth provider.")

(defun valsi-plan--provider ()
  "Return the configured dispatch provider (subscription OAuth by default)."
  (or valsi-plan-agent-provider (valsi-agent-make-anthropic :auth 'oauth)))

(defun valsi-plan--dispatch (root task)
  "Dispatch TASK (in ROOT) to the agent, scoped to its manifest files.
Returns the resulting message transcript."
  (let* ((bundle (valsi-plan-context-bundle root task))
         (files (mapcar #'expand-file-name (plist-get bundle :files)))
         (prompt (valsi-plan-bundle->prompt bundle)))
    (valsi-agent-register-builtin-tools)
    (valsi-agent-scope (:files files)
      (valsi-agent-run
       :provider (valsi-plan--provider)
       :system (valsi-agent-load-instructions)
       :tools (valsi-agent-tools)
       :messages (list (valsi-agent-message
                        "user" (list (valsi-agent-text-block prompt))))))))

(defun valsi-plan-dispatch-task ()
  "Assemble the context bundle for the task at point and dispatch it."
  (interactive)
  (let* ((root (valsi-plan--buffer-tree))
         (task (valsi-plan--task-at-line (valsi-node-of-type root 'task))))
    (unless task (user-error "No task on this line"))
    (valsi-plan--dispatch root task)
    (message "Dispatched %s" (or (valsi-node-prop task :id) "task"))))

(defun valsi-plan-dispatch-next ()
  "Jump to the next actionable task and dispatch it (the agent-handoff loop step)."
  (interactive)
  (valsi-plan-next-actionable)
  (valsi-plan-dispatch-task))

;;;; Verification runner (T702)

(defun valsi-plan-run-verification ()
  "Run the verification command for the task at point in `compilation-mode'."
  (interactive)
  (let* ((root (valsi-plan--buffer-tree))
         (task (valsi-plan--task-at-line (valsi-node-of-type root 'task)))
         (cmd (and task (valsi-plan--verify-command task))))
    (if cmd (compile cmd)
      (message "No verification command for this task"))))

(defun valsi-plan-complete-with-verification ()
  "Run the task's verification; mark it done only on success, else offer to block."
  (interactive)
  (let* ((root (valsi-plan--buffer-tree))
         (task (valsi-plan--task-at-line (valsi-node-of-type root 'task)))
         (cmd (and task (valsi-plan--verify-command task))))
    (unless task (user-error "No task on this line"))
    (if (null cmd)
        (message "No verification command; use `valsi-plan-toggle' to mark done")
      (let ((code (call-process-shell-command cmd nil "*valsi-verify*")))
        (if (zerop code)
            (save-excursion
              (beginning-of-line)
              (when (looking-at valsi-parse-checkbox-re)
                (replace-match "x" t t nil 2))
              (message "Verified %s -> done" (or (valsi-node-prop task :id) "task")))
          (when (y-or-n-p "Verification failed; block this task? ")
            (valsi-plan-block)))))))

;;;; Distill (T704): session outcomes -> plan node-diff

(defun valsi-plan-distill-done (content ids)
  "Return node-diff changes that mark each id in IDS done in plan CONTENT.
The reviewable form of \"the agent finished these tasks\" -- feed to
`valsi-plan-review' / `valsi-plan-apply-changes'."
  (let ((root (valsi-plan-parse content)) changes)
    (dolist (tk (valsi-node-of-type root 'task))
      (let ((id (valsi-node-prop tk :id)))
        (when (and id (member id ids)
                   (not (eq (valsi-node-prop tk :state) 'done)))
          (let* ((old (valsi-plan-review--slice-line content tk))
                 (new (replace-regexp-in-string
                       "\\`\\([ \t]*-[ \t]+\\)\\[.\\]" "\\1[x]" old)))
            (push (list :kind 'modified :id id :old old :new new) changes)))))
    (nreverse changes)))

(defun valsi-plan-distill (session)
  "Propose plan updates from SESSION: mark tasks its transcript reports done.
Scans the session text for `task <id>' / `<id> done' mentions and offers the
resulting node-diff for review."
  (interactive)
  (let* ((text (mapconcat (lambda (m) (or (valsi-agent-message-text m) ""))
                          (valsi-agent-session-messages session) "\n"))
         (root (valsi-plan--buffer-tree))
         (ids (delq nil
                    (mapcar (lambda (tk)
                              (let ((id (valsi-node-prop tk :id)))
                                (and id (string-match-p
                                         (concat "\\_<" (regexp-quote id) "\\_>")
                                         text)
                                     id)))
                            (valsi-node-of-type root 'task))))
         (changes (valsi-plan-distill-done (buffer-string) ids)))
    (if (null changes)
        (message "Valsi distill: nothing to update")
      (valsi-plan-review-update (valsi-plan-apply-changes (buffer-string) changes)))))

(provide 'valsi-plan-agent)
;;; valsi-plan-agent.el ends here

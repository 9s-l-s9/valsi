;;; valsi-plan.el --- Plan/tasks grammar plugin for Valsi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The flagship AAP grammar plugin: plan/tasks files (Spec-Kit, Kiro,
;; Superpowers, GSD, and plain dialects).  Descriptive recognizers R1-R12
;; per design/plan-grammar.md.  Provides the parse, dialect detection,
;; font-lock, and the navigation/state/query/dashboard/lint commands.
;;
;; Registered as a grammar plugin; the client dispatches its :commands.

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-registry)
(require 'valsi-view)

(declare-function project-current "project")
(declare-function project-root "project")
;; Provided by the client (valsi.el): the current buffer's tree in buffer
;; coordinates, fetched through the proto layer and cached.  Commands are the
;; interactive client surface of the grammar, so they read the client's tree
;; rather than reparsing the live buffer.
(declare-function valsi-tree "valsi")

;;;; Parse

(defun valsi-plan-parse (content)
  "Parse CONTENT (a string) into an offset-based plan/tasks node tree."
  (valsi-parse-in-content content #'valsi-plan--parse-current))

(defun valsi-plan--parse-current ()
  "Parse the current buffer into a plan/tasks node tree (buffer positions)."
  (let* ((root (valsi-node-create :type 'plan :beg (point-min) :end (point-max)
                                 :recognizer 'valsi-plan))
         (lines (valsi-parse-lines (current-buffer)))
           (heading-stack nil)          ; (level . group-node)
           (task-stack nil)             ; list of task nodes, deepest first
           (current-group root)
           (current-task nil))
      (dolist (line lines)
        (let* ((text (valsi-line-text line))
               (heading (valsi-parse-heading text))
               (checkbox (valsi-parse-checkbox text)))
          (cond
           ;; Heading -> group
           (heading
            (let ((g (valsi-node-create
                      :type 'group
                      :beg (valsi-line-beg line) :end (valsi-line-end line)
                      :recognizer 'valsi-plan-r4
                      :props (list :level (car heading) :title (cdr heading)))))
              (while (and heading-stack (>= (caar heading-stack) (car heading)))
                (pop heading-stack))
              (if heading-stack
                  (valsi-node-add-child (cdar heading-stack) g)
                (valsi-node-add-child root g))
              (push (cons (car heading) g) heading-stack)
              (setq current-group g task-stack nil current-task nil)))
           ;; Checkbox -> task
           (checkbox
            (let* ((rest (plist-get checkbox :rest))
                   (indent (plist-get checkbox :indent))
                   (id (valsi-parse-id rest))
                   (key (valsi-parse-sort-key id))
                   (task (valsi-node-create
                          :type 'task
                          :beg (valsi-line-beg line) :end (valsi-line-end line)
                          :confidence 'exact
                          :recognizer 'valsi-plan-r1
                          :props (list :state (plist-get checkbox :state)
                                       :char (plist-get checkbox :char)
                                       :id id
                                       :sort-key key
                                       :indent indent
                                       :tags (valsi-parse-tags rest)
                                       :deps (valsi-parse-deps rest)
                                       :pathrefs (valsi-parse-pathrefs rest)
                                       :desc rest
                                       :line (valsi-line-n line)))))
              ;; Find parent: by id-prefix, else by indent, else group.
              (ignore indent key)
              (let ((parent (valsi-plan--find-parent task task-stack)))
                (if parent
                    (valsi-node-add-child parent task)
                  (valsi-node-add-child current-group task)))
              ;; Maintain task stack (drop siblings/deeper).
              (setq task-stack
                    (cons task
                          (cl-remove-if
                           (lambda (tk)
                             (not (valsi-plan--ancestor-p tk task)))
                           task-stack)))
              (setq current-task task)))
           ;; Requirements trace (R6a) -> attach to current task
           ((valsi-parse-requirements text)
            (when current-task
              (valsi-node-put
               current-task :traces
               (append (valsi-node-prop current-task :traces)
                       (valsi-parse-requirements text)))
              (valsi-node-add-child
               current-task
               (valsi-node-create :type 'trace
                                 :beg (valsi-line-beg line) :end (valsi-line-end line)
                                 :recognizer 'valsi-plan-r6a
                                 :props (list :reqs (valsi-parse-requirements text))))))
           ;; Meta label (R4/R9/R10) -> attach to task or group
           ((valsi-parse-meta-label text)
            (let ((m (valsi-node-create
                      :type 'meta
                      :beg (valsi-line-beg line) :end (valsi-line-end line)
                      :recognizer 'valsi-plan-r9
                      :props (list :label (valsi-parse-meta-label text)
                                   :text text))))
              (valsi-node-add-child (or current-task current-group) m)))
           ;; Plain bullet under a task -> step (R7)
           ((and current-task (valsi-parse-bullet text))
            (valsi-node-add-child
             current-task
             (valsi-node-create :type 'step
                               :beg (valsi-line-beg line) :end (valsi-line-end line)
                               :recognizer 'valsi-plan-r7
                               :props (list :text (cdr (valsi-parse-bullet text)))))))))
    (valsi-node-put root :dialect (valsi-plan--detect-dialect root))
    root))

(defun valsi-plan--ancestor-p (candidate task)
  "Return non-nil if CANDIDATE could be an ancestor of TASK.
By id sort-key prefix when both have keys, else by indent."
  (let ((ck (valsi-node-prop candidate :sort-key))
        (tk (valsi-node-prop task :sort-key))
        (ci (valsi-node-prop candidate :indent))
        (ti (valsi-node-prop task :indent)))
    (if (and ck tk)
        (valsi-plan--prefix-p ck tk)
      (< (or ci 0) (or ti 0)))))

(defun valsi-plan--find-parent (task stack)
  "Return the parent node for TASK given the current task STACK."
  (catch 'found
    (dolist (cand stack)
      (when (valsi-plan--ancestor-p cand task)
        (throw 'found cand)))
    nil))

(defun valsi-plan--prefix-p (short long)
  "Return non-nil if list SHORT is a strict prefix of list LONG."
  (and (< (length short) (length long))
       (cl-every #'= short (cl-subseq long 0 (length short)))))

;;;; Effective state (interior tasks derive from children)

(defun valsi-plan-effective-state (task)
  "Return the effective state of TASK (done iff all child tasks done)."
  (let ((children (valsi-node-of-type task 'task)))
    (setq children (cl-remove task children))
    (if (null children)
        (valsi-node-prop task :state)
      (cond ((cl-every (lambda (c) (eq (valsi-plan-effective-state c) 'done))
                       children) 'done)
            ((cl-some (lambda (c) (memq (valsi-plan-effective-state c)
                                        '(in-progress done)))
                      children) 'in-progress)
            (t 'open)))))

;;;; Dialect detection

(defun valsi-plan--detect-dialect (root)
  "Score dialect profiles for ROOT; return the winning profile symbol."
  (let ((speckit 0) (kiro 0) (superpowers 0) (gsd 0))
    (dolist (task (valsi-node-of-type root 'task))
      (let ((id (valsi-node-prop task :id)))
        (cond ((and id (string-prefix-p "T" id)) (cl-incf speckit))
              ((and id (string-match-p "\\`[0-9]" id)) (cl-incf kiro)))
        (when (valsi-node-prop task :traces) (cl-incf kiro))))
    (dolist (g (valsi-node-of-type root 'group))
      (let ((title (valsi-node-prop g :title)))
        (when (and title (string-match-p "\\`Task [0-9]" title))
          (cl-incf superpowers))))
    (with-current-buffer (current-buffer)
      (when (save-excursion (goto-char (point-min))
                            (re-search-forward "^<tasks>" nil t))
        (setq gsd 10)))
    (let ((scores (list (cons 'speckit speckit) (cons 'kiro kiro)
                        (cons 'superpowers superpowers) (cons 'gsd gsd))))
      (car (cl-reduce (lambda (a b) (if (>= (cdr a) (cdr b)) a b)) scores)))))

(defun valsi-plan-detect-dialect ()
  "Report the detected dialect profile for this plan buffer."
  (interactive)
  (let ((dialect (valsi-node-prop (valsi-tree) :dialect)))
    (message "Valsi plan dialect: %s" dialect)
    dialect))

;;;; Capability advertisement (degradation ladder)

(defun valsi-plan-capabilities (root)
  "Advertise supported actions for ROOT per the degradation ladder."
  (let ((tasks (valsi-node-of-type root 'task))
        (caps '(outline narrow)))
    (when tasks
      (setq caps (append caps '(toggle progress next prev occur-state)))
      (when (cl-some (lambda (tk) (valsi-node-prop tk :id)) tasks)
        (setq caps (append caps '(goto info))))
      (when (cl-some (lambda (tk) (or (valsi-node-prop tk :deps)
                                      (valsi-node-prop tk :traces)
                                      (valsi-node-prop tk :pathrefs)))
                     tasks)
        (setq caps (append caps '(follow next-actionable))))
      (setq caps (append caps '(lint dashboard))))
    (delete-dups caps)))

;;;; Font-lock

(defvar valsi-plan-font-lock-keywords
  `((,(concat "^[ \t]*-[ \t]+\\(\\[[xX]\\]\\)[ \t]*\\(.*\\)$")
     (1 'valsi-done-box-face) (2 'valsi-done-face))
    (,(concat "^[ \t]*-[ \t]+\\(\\[[-~/]\\]\\)")
     (1 'valsi-in-progress-face))
    (,(concat "^[ \t]*-[ \t]+\\(\\[ \\]\\)")
     (1 'valsi-open-face))
    (,(concat "^[ \t]*-[ \t]+\\(\\[[^]xX ~/-]\\]\\)")
     (1 'valsi-unknown-face))
    ("^[ \t]*-[ \t]+\\[.\\][ \t]+\\(?:\\[[^]]*\\][ \t]*\\)*\\(T[0-9.]+\\|[0-9]+\\(?:\\.[0-9]+\\)*\\)\\.?\\_>"
     (1 'valsi-id-face))
    ("\\[\\(US[0-9]+\\)\\]" (1 'valsi-story-face))
    ("\\(\\[P\\]\\)" (1 'valsi-tag-face))
    ("(depends on[^)]*)" . 'valsi-dep-face)
    ("_Requirements:[^_]*_" . 'valsi-trace-face)
    ("`[^`\n]*/[^`\n]*`" . 'valsi-trace-face)
    ("^[ \t]*\\*\\*\\(?:Files\\|Verify\\|Goal\\|Purpose\\|Checkpoint\\|Spec\\|Independent Test\\)\\*\\*:?"
     . 'valsi-meta-face))
  "Font-lock keywords for plan/tasks buffers.")

;;;; Navigation & query (rung 2+)

(defconst valsi-plan--task-line-re "^[ \t]*-[ \t]+\\[.\\][ \t]")

(defun valsi-plan-next-task (&optional open-only)
  "Move to the next task line.  With prefix OPEN-ONLY, only open tasks."
  (interactive "P")
  (let ((re (if open-only "^[ \t]*-[ \t]+\\[ \\][ \t]" valsi-plan--task-line-re)))
    (end-of-line)
    (if (re-search-forward re nil t)
        (beginning-of-line)
      (message "No further tasks")
      (forward-line 0))))

(defun valsi-plan-previous-task (&optional open-only)
  "Move to the previous task line.  With prefix OPEN-ONLY, only open tasks."
  (interactive "P")
  (let ((re (if open-only "^[ \t]*-[ \t]+\\[ \\][ \t]" valsi-plan--task-line-re)))
    (beginning-of-line)
    (unless (re-search-backward re nil t)
      (message "No previous tasks"))))

(defun valsi-plan--task-alist (root)
  "Return an alist of (LABEL . POS) for every task in ROOT."
  (mapcar (lambda (tk)
            (cons (format "%s %s"
                          (or (valsi-node-prop tk :id) "-")
                          (truncate-string-to-width
                           (valsi-node-prop tk :desc "") 60))
                  (valsi-node-beg tk)))
          (valsi-node-of-type root 'task)))

(defun valsi-plan-goto-id ()
  "Jump to a task chosen by id/description (completing-read)."
  (interactive)
  (let* ((alist (valsi-plan--task-alist (valsi-tree)))
         (choice (completing-read "Task: " alist nil t)))
    (when-let ((pos (cdr (assoc choice alist))))
      (goto-char pos)
      (beginning-of-line))))

(defun valsi-plan-info-at-point ()
  "Echo a summary of the task at point: state, deps, traces, files."
  (interactive)
  (let* ((root (valsi-tree))
         (task (valsi-node-at-line root (point) 'task)))
    (if (not task)
        (message "No task at point")
      (message
       "%s [%s] deps:%s traces:%s files:%s steps:%d"
       (or (valsi-node-prop task :id) "?")
       (valsi-plan-effective-state task)
       (or (valsi-node-prop task :deps) "-")
       (or (valsi-node-prop task :traces) "-")
       (length (valsi-node-prop task :pathrefs))
       (length (valsi-node-of-type task 'step))))))

(defun valsi-plan-progress ()
  "Report done/total task counts for the buffer."
  (interactive)
  (let* ((root (valsi-tree))
         (tasks (valsi-node-of-type root 'task))
         (leaf (cl-remove-if (lambda (tk) (valsi-node-of-type
                                           tk 'task))
                             ;; leaves: no child tasks
                             tasks))
         (leaf (or leaf tasks))
         (done (cl-count-if (lambda (tk) (eq (valsi-plan-effective-state tk) 'done))
                            leaf))
         (prog (cl-count-if (lambda (tk) (eq (valsi-plan-effective-state tk)
                                             'in-progress))
                            leaf)))
    (message "Valsi plan: %d/%d done, %d in-progress (%d%%)"
             done (length leaf) prog
             (if (zerop (length leaf)) 0
               (round (* 100.0 (/ (float done) (length leaf))))))))

(defun valsi-plan-occur-state ()
  "Occur over tasks filtered by a chosen state."
  (interactive)
  (let* ((state (completing-read "State: "
                                 '("open" "in-progress" "done" "unknown")
                                 nil t))
         (char (pcase state
                 ("open" " ") ("done" "[xX]")
                 ("in-progress" "[-~/]") (_ "."))))
    (occur (format "^[ \t]*-[ \t]+\\[%s\\][ \t]" char))))

(defun valsi-plan-next-actionable ()
  "Jump to the first open task whose dependencies are all satisfied.
Rung 5; falls back to first open task in document order."
  (interactive)
  (let* ((root (valsi-tree))
         (tasks (valsi-node-of-type root 'task))
         (done-ids (delq nil
                         (mapcar (lambda (tk)
                                   (and (eq (valsi-plan-effective-state tk) 'done)
                                        (valsi-node-prop tk :id)))
                                 tasks)))
         (target
          (or (cl-find-if
               (lambda (tk)
                 (and (eq (valsi-node-prop tk :state) 'open)
                      (cl-every (lambda (d) (member d done-ids))
                                (valsi-node-prop tk :deps))))
               tasks)
              (cl-find-if (lambda (tk) (eq (valsi-node-prop tk :state) 'open))
                          tasks))))
    (if target
        (progn (goto-char (valsi-node-beg target)) (beginning-of-line)
               (message "Next actionable: %s" (or (valsi-node-prop target :id)
                                                  (valsi-node-prop target :desc))))
      (message "No actionable open task"))))

;;;; State editing (rung 2+)

(defun valsi-plan-toggle (&optional _arg)
  "Cycle the task at point: open -> in-progress -> done -> open.
On an interior task with children, offer to apply to all children."
  (interactive "P")
  (save-excursion
    (beginning-of-line)
    (if (not (looking-at valsi-parse-checkbox-re))
        (message "No task on this line")
      (let* ((char (match-string 2))
             (state (valsi-parse-state-char char))
             (next (pcase state
                     ('open "-") ('in-progress "x") ('done " ") (_ "x"))))
        (replace-match next t t nil 2)
        (message "Task -> %s" (valsi-parse-state-char next))))))

(defun valsi-plan-block ()
  "Mark the task at point blocked, recording a reason as a child bullet."
  (interactive)
  (let ((reason (read-string "Blocked reason: ")))
    (save-excursion
      (end-of-line)
      (let ((indent (save-excursion (beginning-of-line)
                                    (skip-chars-forward " \t")
                                    (current-column))))
        (insert (format "\n%s  - Blocked: %s (%s)"
                        (make-string indent ?\s) reason
                        (format-time-string "%Y-%m-%d")))))))

;;;; Lint (rung 3+)

(defun valsi-plan-lint ()
  "Report plan health: dangling deps, duplicate ids, placeholders, unknown states."
  (interactive)
  (let* ((root (valsi-tree))
         (tasks (valsi-node-of-type root 'task))
         (ids (delq nil (mapcar (lambda (tk) (valsi-node-prop tk :id)) tasks)))
         (issues nil))
    ;; duplicate ids
    (let ((seen (make-hash-table :test 'equal)))
      (dolist (id ids)
        (puthash id (1+ (gethash id seen 0)) seen))
      (maphash (lambda (id n) (when (> n 1)
                                (push (format "duplicate id %s (%d)" id n) issues)))
               seen))
    ;; dangling deps
    (dolist (tk tasks)
      (dolist (d (valsi-node-prop tk :deps))
        (unless (member d ids)
          (push (format "%s: dangling dep %s"
                        (or (valsi-node-prop tk :id) "?") d) issues)))
      (when (eq (valsi-node-prop tk :state) 'unknown)
        (push (format "%s: unknown state char %S"
                      (or (valsi-node-prop tk :id) "?")
                      (valsi-node-prop tk :char)) issues)))
    ;; placeholders
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "TXXX\\|NEEDS CLARIFICATION\\|\\[FEATURE NAME\\]" nil t)
        (push (format "placeholder %S at line %d"
                      (match-string 0) (line-number-at-pos)) issues)))
    (if (null issues)
        (message "Valsi lint: clean (%d tasks)" (length tasks))
      (with-current-buffer (get-buffer-create "*valsi-plan-lint*")
        (erase-buffer)
        (insert (format "Valsi plan lint: %d issue(s)\n\n" (length issues)))
        (dolist (i (nreverse issues)) (insert "  - " i "\n"))
        (goto-char (point-min))
        (special-mode)
        (display-buffer (current-buffer)))
      (message "Valsi lint: %d issue(s)" (length issues)))))

;;;; Cross-artifact (rung 5)

(defun valsi-plan-follow ()
  "Follow the reference at point: path-ref to a file, or requirement to spec."
  (interactive)
  (cond
   ;; backticked path ref on this line
   ((save-excursion
      (beginning-of-line)
      (when (re-search-forward "`\\([^`\n]*?/[^`\n]*?\\)`" (line-end-position) t)
        (let* ((ref (match-string-no-properties 1))
               (parts (split-string ref ":"))
               (file (car parts))
               (line (and (cadr parts) (string-to-number (cadr parts)))))
          (if (file-exists-p file)
              (progn (find-file-other-window file)
                     (when line (goto-char (point-min)) (forward-line (1- line)))
                     t)
            (message "No such file: %s" file) t)))))
   ((save-excursion
      (beginning-of-line)
      (when (re-search-forward "_Requirements:[ \t]*\\([0-9.]+\\)" (line-end-position) t)
        (message "Requirement %s (open spec/requirements to resolve)"
                 (match-string 1)) t)))
   (t (message "No reference at point"))))

;;;; Dashboard (rung 2 per file)

(defun valsi-plan--project-files ()
  "Return a list of plan/tasks file paths under the current project."
  (let* ((root (or (and (fboundp 'project-current)
                        (project-current)
                        (project-root (project-current)))
                   default-directory))
         (files nil))
    (dolist (pat '("PLAN.md" "specs/*/tasks.md" ".kiro/specs/*/tasks.md"
                   ".planning/*.md" "tasks.md"))
      (setq files (append files (file-expand-wildcards
                                 (expand-file-name pat root) t))))
    (delete-dups files)))

(defun valsi-plan--file-stats (file)
  "Return (DIALECT DONE TOTAL INPROG) for plan FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let* ((root (valsi-plan-parse (buffer-string)))
           (tasks (valsi-node-of-type root 'task))
           (leaves (or (cl-remove-if (lambda (tk) (valsi-node-of-type tk 'task))
                                     tasks)
                       tasks)))
      (list (valsi-node-prop root :dialect)
            (cl-count-if (lambda (tk) (eq (valsi-plan-effective-state tk) 'done))
                         leaves)
            (length leaves)
            (cl-count-if (lambda (tk) (eq (valsi-plan-effective-state tk)
                                          'in-progress))
                         leaves)))))

(defun valsi-plan--dashboard-entries ()
  "Compute tabulated-list entries for the plan dashboard."
  (mapcar
   (lambda (file)
     (let* ((s (valsi-plan--file-stats file))
            (dialect (nth 0 s)) (done (nth 1 s))
            (total (nth 2 s)) (prog (nth 3 s))
            (pct (if (zerop total) 0 (round (* 100.0 (/ (float done) total))))))
       (list file
             (vector (file-relative-name file default-directory)
                     (symbol-name dialect)
                     (format "%d/%d" done total)
                     (format "%d%%" pct)
                     (number-to-string prog)))))
   (valsi-plan--project-files)))

(defun valsi-plan-dashboard ()
  "Show a cross-file agenda of every plan/tasks artifact in the project."
  (interactive)
  (valsi-view-tabulated
   "*Valsi plan agenda*"
   [("File" 40 t) ("Dialect" 12 t) ("Done" 8 t) ("%" 6 t) ("WIP" 5 t)]
   (valsi-plan--dashboard-entries)
   #'valsi-plan--dashboard-entries)
  (define-key valsi-view-list-mode-map (kbd "RET") #'valsi-plan--dashboard-visit))

(defun valsi-plan--dashboard-visit ()
  "Open the plan file on the current dashboard row."
  (interactive)
  (let ((file (tabulated-list-get-id)))
    (when file (find-file-other-window file))))

;;;; Registration

(defun valsi-plan-match (uri text)
  "Return a match score for a document URI + TEXT as a plan/tasks file."
  (let ((name (or uri ""))
        (score 0))
    (when (string-match-p "\\(tasks\\|PLAN\\|plan\\)\\.md\\'" name)
      (cl-incf score 3))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (when (re-search-forward "^[ \t]*-[ \t]+\\[.\\][ \t]" nil t)
        (cl-incf score 2))
      (goto-char (point-min))
      (when (re-search-forward "^[ \t]*-[ \t]+\\[.\\][ \t]+\\(T[0-9]\\|[0-9]+\\.\\)" nil t)
        (cl-incf score 3))
      (goto-char (point-min))
      (when (re-search-forward "_Requirements:" nil t) (cl-incf score 2)))
    score))

(defun valsi-plan-register ()
  "Register the plan/tasks grammar plugin."
  (valsi-registry-register
   (list :id 'plan
         :name "Plan / Tasks"
         :evidence 'emergent
         :match #'valsi-plan-match
         :parse #'valsi-plan-parse
         :font-lock valsi-plan-font-lock-keywords
         :capabilities #'valsi-plan-capabilities
         :commands '((next . valsi-plan-next-task)
                     (prev . valsi-plan-previous-task)
                     (goto . valsi-plan-goto-id)
                     (toggle . valsi-plan-toggle)
                     (info . valsi-plan-info-at-point)
                     (progress . valsi-plan-progress)
                     (occur-state . valsi-plan-occur-state)
                     (next-actionable . valsi-plan-next-actionable)
                     (block . valsi-plan-block)
                     (lint . valsi-plan-lint)
                     (follow . valsi-plan-follow)
                     (dashboard . valsi-plan-dashboard)
                     (detect . valsi-plan-detect-dialect)))))

(provide 'valsi-plan)
;;; valsi-plan.el ends here

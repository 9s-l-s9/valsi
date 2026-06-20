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
(require 'flymake)
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
      (setq caps (append caps '(toggle progress next prev occur-state
                                insert split complete-children
                                move-up move-down promote-step demote)))
      (when (cl-some (lambda (tk) (valsi-node-prop tk :id)) tasks)
        (setq caps (append caps '(goto info add-dep)))
        (when (eq (valsi-node-prop root :dialect) 'speckit)
          (setq caps (append caps '(renumber)))))
      (when (cl-some (lambda (tk) (or (valsi-node-prop tk :deps)
                                      (valsi-node-prop tk :traces)
                                      (valsi-node-prop tk :pathrefs)))
                     tasks)
        (setq caps (append caps '(follow follow-trace next-actionable))))
      (when (cl-some (lambda (tk) (valsi-node-prop tk :traces)) tasks)
        (setq caps (append caps '(coverage))))
      (when (cl-some (lambda (tk) (valsi-node-prop tk :pathrefs)) tasks)
        (setq caps (append caps '(stale-check))))
      (setq caps (append caps '(lint flymake dashboard))))
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

;;;; Structure editing (rung 3-4): insert / renumber / add-dep

(defun valsi-plan--buffer-tree ()
  "Parse the current buffer fresh (mutation commands re-derive, never cache)."
  (valsi-plan-parse (buffer-string)))

(defun valsi-plan--max-tnum (root)
  "Return the highest N among speckit-style Tnnn ids in ROOT (0 if none)."
  (let ((max 0))
    (dolist (tk (valsi-node-of-type root 'task))
      (let ((id (valsi-node-prop tk :id)))
        (when (and id (string-match "\\`T\\([0-9]+\\)\\'" id))
          (setq max (max max (string-to-number (match-string 1 id)))))))
    max))

(defun valsi-plan--max-int-id (root)
  "Return the highest top-level integer among kiro-style ids in ROOT (0 if none)."
  (let ((max 0))
    (dolist (tk (valsi-node-of-type root 'task))
      (let ((id (valsi-node-prop tk :id)))
        (when (and id (string-match "\\`\\([0-9]+\\)\\'" id))
          (setq max (max max (string-to-number (match-string 1 id)))))))
    max))

(defun valsi-plan-insert-task (desc)
  "Insert a new open task after point, numbered in the buffer's dialect.
DESC is the task description.  Speckit buffers get the next Tnnn id, kiro
buffers the next integer id; other dialects get no id."
  (interactive "sTask description: ")
  (let* ((root (valsi-plan--buffer-tree))
         (dialect (valsi-node-prop root :dialect))
         (indent (save-excursion
                   (beginning-of-line)
                   (buffer-substring-no-properties
                    (point) (progn (skip-chars-forward " \t") (point)))))
         (id (pcase dialect
               ('speckit (format "T%03d" (1+ (valsi-plan--max-tnum root))))
               ('kiro (number-to-string (1+ (valsi-plan--max-int-id root))))
               (_ nil))))
    (end-of-line)
    (insert (format "\n%s- [ ] %s%s" indent (if id (concat id " ") "") desc))
    (message "Inserted %s" (or id "task"))))

(defun valsi-plan--reaches-p (from target tasks &optional seen)
  "Return non-nil if task id FROM transitively depends on id TARGET.
TASKS is the task-node list; SEEN guards against existing cycles."
  (unless (member from seen)
    (let ((node (cl-find-if (lambda (tk) (equal (valsi-node-prop tk :id) from))
                            tasks)))
      (when node
        (let ((deps (valsi-node-prop node :deps)))
          (or (member target deps)
              (cl-some (lambda (d)
                         (valsi-plan--reaches-p d target tasks (cons from seen)))
                       deps)))))))

(defun valsi-plan--task-at-line (tasks)
  "Return the task node in TASKS on the current buffer line, or nil."
  (let ((ln (line-number-at-pos)))          ; 1-based
    (cl-find-if (lambda (tk) (= (1+ (or (valsi-node-prop tk :line) -1)) ln))
                tasks)))

(defun valsi-plan-add-dep ()
  "Add a dependency to the task at point, refusing to create a cycle."
  (interactive)
  (let* ((root (valsi-plan--buffer-tree))
         (tasks (valsi-node-of-type root 'task))
         (ids (delq nil (mapcar (lambda (tk) (valsi-node-prop tk :id)) tasks)))
         (cur (valsi-plan--task-at-line tasks)))
    (unless cur (user-error "No task on this line"))
    (let* ((cur-id (valsi-node-prop cur :id))
           (dep (completing-read "Depends on: " (remove cur-id ids) nil t)))
      (when (equal dep cur-id) (user-error "A task cannot depend on itself"))
      (when (and cur-id (valsi-plan--reaches-p dep cur-id tasks))
        (user-error "Refusing: %s already depends on %s (cycle)" dep cur-id))
      (valsi-plan--insert-dep-on-line dep)
      (message "%s now depends on %s" (or cur-id "task") dep))))

(defun valsi-plan--insert-dep-on-line (dep)
  "Add DEP to the task line at point, merging into an existing deps group."
  (save-excursion
    (beginning-of-line)
    (let ((eol (line-end-position)))
      (if (re-search-forward valsi-parse-dep-re eol t)
          (progn (goto-char (1- (match-end 0))) ; just before the closing paren
                 (insert ", " dep))
        (goto-char eol)
        (insert (format " (depends on %s)" dep))))))

(defun valsi-plan-renumber ()
  "Normalize speckit Tnnn ids to sequential document order.
Rewrites every id and every `depends on' reference in a single undo group.
Refuses on non-speckit dialects (positional ids are meaningful there)."
  (interactive)
  (let* ((root (valsi-plan--buffer-tree))
         (dialect (valsi-node-prop root :dialect)))
    (unless (eq dialect 'speckit)
      (user-error "valsi-plan-renumber supports the speckit Tnnn dialect only (this is %s)"
                  dialect))
    (let* ((ordered (sort (cl-remove-if-not
                           (lambda (tk)
                             (let ((id (valsi-node-prop tk :id)))
                               (and id (string-match-p "\\`T[0-9]+\\'" id))))
                           (valsi-node-of-type root 'task))
                          (lambda (a b) (< (or (valsi-node-prop a :line) 0)
                                           (or (valsi-node-prop b :line) 0)))))
           (map (make-hash-table :test 'equal))
           (n 0) (changed 0))
      (dolist (tk ordered)
        (cl-incf n)
        (puthash (valsi-node-prop tk :id) (format "T%03d" n) map))
      (atomic-change-group
        (save-excursion
          (goto-char (point-min))
          ;; Match full dotted ids so a sub-id (T001.1) is never confused with a
          ;; top-level id (T001); only exact map keys are rewritten.  Reading the
          ;; original token and writing the new one in one pass is collision-free.
          (while (re-search-forward "\\bT[0-9]+\\(?:\\.[0-9]+\\)*" nil t)
            (let* ((old (match-string-no-properties 0))
                   (new (gethash old map)))
              (when (and new (not (string= old new)))
                (replace-match new t t)
                (cl-incf changed))))))
      (message "valsi-plan-renumber: %d task(s), %d reference(s) rewritten"
               n changed))))

(defun valsi-plan--dialect-next-id (root)
  "Return the next task id string for ROOT's dialect, or nil if unnumbered."
  (pcase (valsi-node-prop root :dialect)
    ('speckit (format "T%03d" (1+ (valsi-plan--max-tnum root))))
    ('kiro (number-to-string (1+ (valsi-plan--max-int-id root))))
    (_ nil)))

(defun valsi-plan--subtree-end (task)
  "Return the maximum END offset spanned by TASK and all its descendants."
  (let ((mx (or (valsi-node-end task) 0)))
    (valsi-node-walk task (lambda (n _d)
                           (when (valsi-node-end n)
                             (setq mx (max mx (valsi-node-end n))))))
    mx))

(defun valsi-plan--task-region (task)
  "Return (BEG . END) buffer positions covering TASK and its whole subtree."
  (cons (+ (valsi-node-beg task) (point-min))
        (+ (valsi-plan--subtree-end task) (point-min))))

(defun valsi-plan--parent-of (root task)
  "Return the node in ROOT whose direct children include TASK, or nil."
  (let (parent)
    (valsi-node-walk root (lambda (n _d)
                           (when (memq task (valsi-node-children n))
                             (setq parent n))))
    parent))

(defun valsi-plan-complete-with-children ()
  "Mark the task at point done, and every descendant task done too (Kiro interior)."
  (interactive)
  (let* ((root (valsi-plan--buffer-tree))
         (task (valsi-plan--task-at-line (valsi-node-of-type root 'task))))
    (unless task (user-error "No task on this line"))
    (let ((region (valsi-plan--task-region task)) (n 0))
      (atomic-change-group
        (save-excursion
          (goto-char (car region))
          (while (< (point) (cdr region))
            (when (looking-at valsi-parse-checkbox-re)
              (replace-match "x" t t nil 2) (cl-incf n))
            (forward-line 1))))
      (message "Completed %d task(s) with children" n))))

(defun valsi-plan-split-task ()
  "Split the task at point in two: text after point becomes a new task below."
  (interactive)
  (let* ((root (valsi-plan--buffer-tree))
         (id (valsi-plan--dialect-next-id root)))
    (save-excursion (beginning-of-line)
                    (unless (looking-at valsi-parse-checkbox-re)
                      (user-error "No task on this line")))
    (let ((indent (save-excursion
                    (beginning-of-line)
                    (buffer-substring-no-properties
                     (point) (progn (skip-chars-forward " \t") (point)))))
          (rest (string-trim-left
                 (buffer-substring-no-properties (point) (line-end-position)))))
      (atomic-change-group
        (delete-region (point) (line-end-position))
        (insert (format "\n%s- [ ] %s%s" indent (if id (concat id " ") "") rest)))
      (message "Split into %s" (or id "a new task")))))

(defun valsi-plan-promote-step ()
  "Turn the plain step bullet at point into a full task with a new dialect id."
  (interactive)
  (save-excursion
    (beginning-of-line)
    (unless (and (looking-at valsi-parse-bullet-re)
                 (not (looking-at valsi-parse-checkbox-re)))
      (user-error "Not on a plain step bullet")))
  (let ((id (valsi-plan--dialect-next-id (valsi-plan--buffer-tree))))
    (save-excursion
      (beginning-of-line)
      (re-search-forward valsi-parse-bullet-re (line-end-position))
      (let ((indent (match-string-no-properties 1))
            (body (match-string-no-properties 2)))
        (replace-match (format "%s- [ ] %s%s" indent (if id (concat id " ") "") body)
                       t t)))
    (message "Promoted step -> %s" (or id "task"))))

(defconst valsi-plan--leading-id-re
  "\\`\\(?:\\[[^]]*\\][ \t]*\\)*\\(?:T[0-9]+\\|[0-9]+\\(?:\\.[0-9]+\\)*\\)\\.?[ \t]+"
  "A leading task-id token (with optional preceding tags), for stripping.")

(defun valsi-plan-demote-task ()
  "Turn the task at point into a plain step bullet (drop the checkbox and id)."
  (interactive)
  (save-excursion
    (beginning-of-line)
    (unless (looking-at valsi-parse-checkbox-re)
      (user-error "No task on this line"))
    (let* ((indent (match-string-no-properties 1))
           (rest (match-string-no-properties 3))
           (lbeg (line-beginning-position))
           (lend (line-end-position))
           ;; string-match below clobbers the buffer match data, so we edit by
           ;; region rather than `replace-match'.
           (rest (if (string-match valsi-plan--leading-id-re rest)
                     (substring rest (match-end 0))
                   rest)))
      (delete-region lbeg lend)
      (goto-char lbeg)
      (insert (format "%s- %s" indent rest))))
  (message "Demoted task -> step"))

(defun valsi-plan--move (dir)
  "Move the task subtree at point past its DIR sibling (`up' or `down').
Refuses a move that would place a task on the wrong side of a dependency."
  (let* ((root (valsi-plan--buffer-tree))
         (tasks (valsi-node-of-type root 'task))
         (task (valsi-plan--task-at-line tasks)))
    (unless task (user-error "No task on this line"))
    (let* ((parent (or (valsi-plan--parent-of root task) root))
           (siblings (cl-remove-if-not
                      (lambda (c) (eq (valsi-node-type c) 'task))
                      (valsi-node-children parent)))
           (idx (cl-position task siblings))
           (sib (and idx (if (eq dir 'up)
                             (and (> idx 0) (nth (1- idx) siblings))
                           (nth (1+ idx) siblings)))))
      (unless sib (user-error "No sibling task to move %s" dir))
      ;; dep-order guard
      (let ((tid (valsi-node-prop task :id))
            (sid (valsi-node-prop sib :id)))
        (cond
         ((and (eq dir 'up) sid (member sid (valsi-node-prop task :deps)))
          (user-error "Refusing: %s depends on %s (must stay below it)" tid sid))
         ((and (eq dir 'down) tid (member tid (valsi-node-prop sib :deps)))
          (user-error "Refusing: %s depends on %s (must stay below it)" sid tid))))
      (let* ((tr (valsi-plan--task-region task))
             (sr (valsi-plan--task-region sib))
             (task-text (buffer-substring (car tr) (cdr tr))))
        (atomic-change-group
          (if (eq dir 'up)
              (progn (delete-region (car tr) (cdr tr))
                     (goto-char (car sr))
                     (insert task-text))
            ;; down: insert after the sibling, then delete the original.
            (goto-char (cdr sr))
            (save-excursion (insert task-text))
            (delete-region (car tr) (cdr tr))))
        (goto-char (car sr))
        (beginning-of-line))
      (message "Moved %s %s" (or (valsi-node-prop task :id) "task") dir))))

(defun valsi-plan-move-task-up ()
  "Move the task at point above its previous sibling (dep-order guarded)."
  (interactive)
  (valsi-plan--move 'up))

(defun valsi-plan-move-task-down ()
  "Move the task at point below its next sibling (dep-order guarded)."
  (interactive)
  (valsi-plan--move 'down))

;;;; Lint (rung 3+)

(defun valsi-plan--lint-collect (root)
  "Return structural lint findings for parse tree ROOT.
Each finding is (NODE . MESSAGE); NODE is the offending task node (or nil for a
document-global finding).  Pure over the tree (no buffer, no filesystem):
duplicate ids, dangling deps, unknown state chars, dependency cycles, and
interior-state contradictions.  `valsi-plan-lint' and the flymake backend both
build on this; the buffer/filesystem checks are layered on top there."
  (let* ((tasks (valsi-node-of-type root 'task))
         (ids (delq nil (mapcar (lambda (tk) (valsi-node-prop tk :id)) tasks)))
         (found nil))
    ;; duplicate ids (document-global)
    (let ((seen (make-hash-table :test 'equal)))
      (dolist (id ids)
        (puthash id (1+ (gethash id seen 0)) seen))
      (maphash (lambda (id n)
                 (when (> n 1)
                   (push (cons nil (format "duplicate id %s (%d)" id n)) found)))
               seen))
    (dolist (tk tasks)
      (let ((id (or (valsi-node-prop tk :id) "?")))
        ;; dangling deps
        (dolist (d (valsi-node-prop tk :deps))
          (unless (member d ids)
            (push (cons tk (format "%s: dangling dep %s" id d)) found)))
        ;; unknown state char
        (when (eq (valsi-node-prop tk :state) 'unknown)
          (push (cons tk (format "%s: unknown state char %S" id
                                 (valsi-node-prop tk :char)))
                found))
        ;; dependency cycle: a task that transitively depends on itself
        (let ((self (valsi-node-prop tk :id)))
          (when (and self (valsi-plan--reaches-p self self tasks))
            (push (cons tk (format "%s: dependency cycle" self)) found)))
        ;; interior-state contradiction: marked done but a child is not done
        (when (and (eq (valsi-node-prop tk :state) 'done)
                   (not (eq (valsi-plan-effective-state tk) 'done)))
          (push (cons tk (format "%s: marked done but has an unfinished child" id))
                found))))
    (nreverse found)))

(defun valsi-plan--lint-issues (root)
  "Return the structural lint messages for ROOT as a list of strings."
  (mapcar #'cdr (valsi-plan--lint-collect root)))

(defun valsi-plan--missing-file-findings (root &optional dir)
  "Return (NODE . MESSAGE) findings for done tasks whose manifest files are gone.
DIR (default `default-directory') resolves relative path-refs."
  (let ((dir (or dir default-directory)) (found nil))
    (dolist (tk (valsi-node-of-type root 'task))
      (when (eq (valsi-plan-effective-state tk) 'done)
        (dolist (pr (valsi-node-prop tk :pathrefs))
          (let ((file (car (split-string pr ":"))))
            (unless (file-exists-p (expand-file-name file dir))
              (push (cons tk (format "%s: done but manifest file missing: %s"
                                     (or (valsi-node-prop tk :id) "?") file))
                    found))))))
    (nreverse found)))

(defun valsi-plan-lint ()
  "Report plan health: dangling deps, duplicate ids, cycles, interior-state
contradictions, missing manifest files, placeholders, and unknown state chars."
  (interactive)
  (let* ((root (valsi-tree))
         (tasks (valsi-node-of-type root 'task))
         (placeholders nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "TXXX\\|NEEDS CLARIFICATION\\|\\[FEATURE NAME\\]" nil t)
        (push (format "placeholder %S at line %d"
                      (match-string 0) (line-number-at-pos)) placeholders)))
    (let ((issues (append (valsi-plan--lint-issues root)
                          (mapcar #'cdr (valsi-plan--missing-file-findings root))
                          (nreverse placeholders))))
      (if (null issues)
          (message "Valsi lint: clean (%d tasks)" (length tasks))
        (with-current-buffer (get-buffer-create "*valsi-plan-lint*")
          (erase-buffer)
          (insert (format "Valsi plan lint: %d issue(s)\n\n" (length issues)))
          (dolist (i issues) (insert "  - " i "\n"))
          (goto-char (point-min))
          (special-mode)
          (display-buffer (current-buffer)))
        (message "Valsi lint: %d issue(s)" (length issues))))))

;;;; Flymake backend (rung 3-4): live diagnostics from the lint collector

(defun valsi-plan-flymake (report-fn &rest _)
  "Flymake backend: report `valsi-plan--lint-collect' findings as diagnostics.
Registered by `valsi-plan-flymake-setup'.  Parses the current buffer fresh."
  (let* ((root (valsi-plan--buffer-tree))
         (diags nil))
    (dolist (pair (append (valsi-plan--lint-collect root)
                          (valsi-plan--missing-file-findings root)))
      (let* ((node (car pair)) (msg (cdr pair))
             (beg (if node (+ (valsi-node-beg node) (point-min)) (point-min)))
             (beg (min beg (point-max)))
             (end (save-excursion (goto-char beg)
                                  (min (point-max) (line-end-position)))))
        (push (flymake-make-diagnostic (current-buffer) beg (max end (1+ beg))
                                       :warning msg)
              diags)))
    (funcall report-fn diags)))

(defun valsi-plan-flymake-setup ()
  "Enable the Valsi plan lint flymake backend in the current buffer."
  (interactive)
  (add-hook 'flymake-diagnostic-functions #'valsi-plan-flymake nil t)
  (flymake-mode 1))

;;;; Cross-artifact: trace resolution (rung 5)

(defun valsi-plan--sibling-file (names)
  "Return the first existing sibling among NAMES beside the current file, or nil."
  (when buffer-file-name
    (let ((dir (file-name-directory buffer-file-name)))
      (cl-some (lambda (n) (let ((f (expand-file-name n dir)))
                             (and (file-exists-p f) f)))
               names))))

(defun valsi-plan--requirements-file ()
  "Return the sibling requirements/spec file for the current plan, or nil."
  (valsi-plan--sibling-file '("requirements.md" "spec.md" "requirements.markdown")))

(defun valsi-plan--requirement-anchor-re (id)
  "Return a regexp locating requirement/story ID as a whole token."
  (concat "\\_<" (regexp-quote id) "\\_>"))

(defun valsi-plan--follow-pathref-at-point ()
  "If a backtick path-ref is on this line, visit it.  Return non-nil if handled."
  (save-excursion
    (beginning-of-line)
    (when (re-search-forward "`\\([^`\n]*?/[^`\n]*?\\)`" (line-end-position) t)
      (let* ((ref (match-string-no-properties 1))
             (parts (split-string ref ":"))
             (file (car parts))
             (line (and (cadr parts) (string-to-number (cadr parts)))))
        (if (file-exists-p file)
            (progn (find-file-other-window file)
                   (when line (goto-char (point-min)) (forward-line (1- line))))
          (message "No such file: %s" file))
        t))))

(defun valsi-plan--follow-anchor (file id kind)
  "Visit FILE and jump to token ID (KIND is a label for messages).  Non-nil."
  (if (not file)
      (message "%s %s (no requirements/spec sibling found)" kind id)
    (find-file-other-window file)
    (goto-char (point-min))
    (if (re-search-forward (valsi-plan--requirement-anchor-re id) nil t)
        (beginning-of-line)
      (message "%s %s not found in %s" kind id (file-name-nondirectory file))))
  t)

(defun valsi-plan--follow-requirement-at-point ()
  "If a `_Requirements: n.m_` trace is on this line, jump to it.  Non-nil if so."
  (let ((reqs (save-excursion
                (beginning-of-line)
                (valsi-parse-requirements
                 (buffer-substring-no-properties (point) (line-end-position))))))
    (when reqs
      (valsi-plan--follow-anchor (valsi-plan--requirements-file)
                                (car reqs) "Requirement"))))

(defun valsi-plan--follow-story-at-point ()
  "If a `[USn]` story tag is on this line, jump to the story.  Non-nil if so."
  (let ((story (save-excursion
                 (beginning-of-line)
                 (when (re-search-forward "\\[\\(US[0-9]+\\)\\]" (line-end-position) t)
                   (match-string-no-properties 1)))))
    (when story
      (valsi-plan--follow-anchor
       (valsi-plan--sibling-file '("spec.md" "requirements.md")) story "Story"))))

(defun valsi-plan-follow-trace ()
  "Resolve the trace reference on the task line at point.
Tries, in order: a backtick path-ref (→ file:line), a `_Requirements: n.m_`
trace (→ the matching item in the sibling requirements.md), and a `[USn]` story
tag (→ the user story in spec.md)."
  (interactive)
  (or (valsi-plan--follow-pathref-at-point)
      (valsi-plan--follow-requirement-at-point)
      (valsi-plan--follow-story-at-point)
      (message "No resolvable trace on this line")))

;; `follow' keeps its original name as the generic entry point.
(defalias 'valsi-plan-follow #'valsi-plan-follow-trace
  "Follow the reference at point (path-ref, requirement, or story).")

;;;; Cross-artifact: coverage (rung 5)

(defun valsi-plan--coverage (root)
  "Return an alist (REQ-ID . (TASK-ID ...)) of requirements ROOT's tasks trace to.
Sorted by requirement sort key."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (tk (valsi-node-of-type root 'task))
      (dolist (req (valsi-node-prop tk :traces))
        (push (or (valsi-node-prop tk :id) "?") (gethash req table nil))))
    (let (out)
      (maphash (lambda (req ids) (push (cons req (nreverse ids)) out)) table)
      (sort out (lambda (a b)
                  (valsi-parse-sort-key< (valsi-parse-sort-key (car a))
                                        (valsi-parse-sort-key (car b))))))))

(defun valsi-plan--defined-requirements (file)
  "Return the requirement ids (n.m) declared in requirements FILE, in order."
  (let (ids)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*\\([0-9]+\\.[0-9]+\\)[ \t.:)]" nil t)
        (push (match-string-no-properties 1) ids)))
    (delete-dups (nreverse ids))))

(defun valsi-plan-coverage ()
  "Show a requirements↔tasks coverage table; zero-task requirements are flagged."
  (interactive)
  (let* ((root (valsi-tree))
         (covered (valsi-plan--coverage root))
         (req-file (valsi-plan--requirements-file))
         (defined (and req-file (valsi-plan--defined-requirements req-file)))
         ;; union of defined + referenced requirement ids
         (all (cl-remove-duplicates
               (append defined (mapcar #'car covered)) :test #'equal :from-end t))
         (all (sort all (lambda (a b)
                          (valsi-parse-sort-key< (valsi-parse-sort-key a)
                                                (valsi-parse-sort-key b)))))
         (entries
          (mapcar
           (lambda (req)
             (let* ((tasks (cdr (assoc req covered)))
                    (label (if tasks (string-join tasks ", ") "— none —")))
               (list req (vector req
                                 (number-to-string (length tasks))
                                 (if tasks label
                                   (propertize label 'face 'valsi-open-face))))))
           all)))
    (valsi-view-tabulated
     "*Valsi plan coverage*"
     [("Requirement" 16 t) ("#Tasks" 8 t) ("Tasks" 60 nil)]
     entries)))

;;;; Cross-artifact: staleness (rung 5)

(defun valsi-plan--stale-tasks (root plan-file)
  "Return (TASK-ID . FILE) pairs where a task's path-ref target is newer than
PLAN-FILE (its trace target changed after the plan was last written)."
  (let ((plan-mtime (and (file-exists-p plan-file)
                         (file-attribute-modification-time
                          (file-attributes plan-file))))
        (dir (file-name-directory plan-file))
        out)
    (when plan-mtime
      (dolist (tk (valsi-node-of-type root 'task))
        (dolist (pr (valsi-node-prop tk :pathrefs))
          (let* ((file (car (split-string pr ":")))
                 (abs (expand-file-name file dir)))
            (when (and (file-exists-p abs)
                       (time-less-p plan-mtime
                                    (file-attribute-modification-time
                                     (file-attributes abs))))
              (push (cons (or (valsi-node-prop tk :id) "?") file) out))))))
    (nreverse out)))

(defun valsi-plan-stale-check ()
  "Flag tasks whose referenced files are newer than this plan file (git mtime)."
  (interactive)
  (unless buffer-file-name
    (user-error "Buffer is not visiting a file"))
  (let ((stale (valsi-plan--stale-tasks (valsi-tree) buffer-file-name)))
    (if (null stale)
        (message "Valsi stale-check: no tasks trailing their targets")
      (with-current-buffer (get-buffer-create "*valsi-plan-stale*")
        (erase-buffer)
        (insert (format "Valsi stale-check: %d task(s) with newer targets\n\n"
                        (length stale)))
        (dolist (s stale)
          (insert (format "  - %s: %s changed since the plan\n" (car s) (cdr s))))
        (goto-char (point-min))
        (special-mode)
        (display-buffer (current-buffer)))
      (message "Valsi stale-check: %d task(s) trailing their targets"
               (length stale)))))

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
                     (insert . valsi-plan-insert-task)
                     (split . valsi-plan-split-task)
                     (complete-children . valsi-plan-complete-with-children)
                     (promote-step . valsi-plan-promote-step)
                     (demote . valsi-plan-demote-task)
                     (move-up . valsi-plan-move-task-up)
                     (move-down . valsi-plan-move-task-down)
                     (add-dep . valsi-plan-add-dep)
                     (renumber . valsi-plan-renumber)
                     (lint . valsi-plan-lint)
                     (flymake . valsi-plan-flymake-setup)
                     (follow-trace . valsi-plan-follow-trace)
                     (coverage . valsi-plan-coverage)
                     (stale-check . valsi-plan-stale-check)
                     (follow . valsi-plan-follow)
                     (dashboard . valsi-plan-dashboard)
                     (detect . valsi-plan-detect-dialect)))))

(provide 'valsi-plan)
;;; valsi-plan.el ends here

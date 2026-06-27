;;; valsi-plan-review.el --- Node-diff review for agent plan edits -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; "Write through the grammar" made concrete (Sprint 7, T703): after an agent
;; edits a plan, Valsi shows a *node-level structural diff* -- which tasks were
;; added / removed / modified -- and lets the user accept or reject each change,
;; then applies only the accepted ones.  Never a silent overwrite.
;;
;; The diff is keyed by task id, so it is stable under reordering and robust to
;; the agent rewriting whole regions.  Reject-all restores the file
;; byte-identically (the core invariant); accept-all yields the agent's version.

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-plan)
(require 'valsi-view)

;;;; Line slicing

(defun valsi-plan-review--slice-line (content node)
  "Return NODE's line text sliced from CONTENT (0-based offsets), no trailing NL."
  (string-trim-right
   (substring content (valsi-node-beg node)
              (min (length content) (valsi-node-end node)))
   "\n"))

(defun valsi-plan-review--id->line (content)
  "Return an alist of (ID . LINE-TEXT) for id-bearing tasks parsed from CONTENT."
  (delq nil
        (mapcar (lambda (tk)
                  (let ((id (valsi-node-prop tk :id)))
                    (and id (cons id (valsi-plan-review--slice-line content tk)))))
                (valsi-node-of-type (valsi-plan-parse content) 'task))))

;;;; Diff

(defun valsi-plan-diff (old-content new-content)
  "Return the task-level node diff from OLD-CONTENT to NEW-CONTENT.
Each change is a plist (:kind KIND :id ID :old LINE :new LINE); KIND is
`added', `removed', or `modified'.  Tasks are matched by id; un-ided tasks are
ignored (their dialects are positional and handled by `renumber')."
  (let ((old (valsi-plan-review--id->line old-content))
        (new (valsi-plan-review--id->line new-content))
        changes)
    (dolist (pair old)
      (let* ((id (car pair)) (old-line (cdr pair))
             (new-line (cdr (assoc id new))))
        (cond ((null new-line)
               (push (list :kind 'removed :id id :old old-line) changes))
              ((not (string= old-line new-line))
               (push (list :kind 'modified :id id :old old-line :new new-line)
                     changes)))))
    (dolist (pair new)
      (unless (assoc (car pair) old)
        (push (list :kind 'added :id (car pair) :new (cdr pair)) changes)))
    (nreverse changes)))

;;;; Apply

(defun valsi-plan-review--goto-task-line (id)
  "Move point to the start of the task line with ID; return point or nil."
  (goto-char (point-min))
  (catch 'found
    (while (not (eobp))
      (let* ((text (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position)))
             (cb (valsi-parse-checkbox text)))
        (when (and cb (equal id (valsi-parse-id (plist-get cb :rest))))
          (throw 'found (line-beginning-position))))
      (forward-line 1))
    nil))

(defun valsi-plan-apply-changes (old-content changes)
  "Return OLD-CONTENT with the accepted CHANGES applied, line-level, keyed by id.
An empty CHANGES list returns OLD-CONTENT byte-identically (reject-all)."
  (with-temp-buffer
    (insert old-content)
    (dolist (ch changes)
      (pcase (plist-get ch :kind)
        ('modified
         (when (valsi-plan-review--goto-task-line (plist-get ch :id))
           (delete-region (line-beginning-position) (line-end-position))
           (insert (plist-get ch :new))))
        ('removed
         (when (valsi-plan-review--goto-task-line (plist-get ch :id))
           (delete-region (line-beginning-position)
                          (min (point-max) (1+ (line-end-position))))))
        ('added
         (goto-char (point-max))
         (unless (or (bobp) (eq (char-before) ?\n)) (insert "\n"))
         (insert (plist-get ch :new) "\n"))))
    (buffer-string)))

;;;; Interactive review buffer

(defvar-local valsi-plan-review--changes nil
  "The (CHANGE . ACCEPTED) rows under review in this buffer.")
(defvar-local valsi-plan-review--target nil
  "The buffer whose content is being reviewed.")
(defvar-local valsi-plan-review--old nil
  "The original content string under review.")

(defun valsi-plan-review--kind-label (ch)
  "Return a short human label for change CH."
  (pcase (plist-get ch :kind)
    ('added (format "+ %s" (plist-get ch :new)))
    ('removed (format "- %s" (plist-get ch :old)))
    ('modified (format "~ %s  =>  %s" (plist-get ch :old) (plist-get ch :new)))))

(defun valsi-plan-review-update (new-content)
  "Review NEW-CONTENT (an agent's proposed edit) against the current buffer.
Pops up a review buffer enumerating the task-level changes; accept/reject per
node, then apply.  With no changes, reports so and does nothing."
  (interactive)
  (let* ((target (current-buffer))
         (old (buffer-string))
         (changes (valsi-plan-diff old new-content)))
    (if (null changes)
        (message "Valsi review: no task-level changes")
      (let ((buf (get-buffer-create "*valsi-plan-review*")))
        (with-current-buffer buf
          (valsi-plan-review-mode)
          (setq valsi-plan-review--target target
                valsi-plan-review--old old
                valsi-plan-review--changes
                (mapcar (lambda (c) (cons c t)) changes)) ; accepted by default
          (valsi-plan-review--refresh))
        (pop-to-buffer buf)))))

(defvar valsi-plan-review-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "t") #'valsi-plan-review-toggle)
    (define-key m (kbd "TAB") #'valsi-plan-review-toggle)
    (define-key m (kbd "a") #'valsi-plan-review-accept-all)
    (define-key m (kbd "r") #'valsi-plan-review-reject-all)
    (define-key m (kbd "RET") #'valsi-plan-review-apply)
    (define-key m (kbd "q") #'quit-window)
    m)
  "Keymap for `valsi-plan-review-mode'.")

(define-derived-mode valsi-plan-review-mode special-mode "Valsi-Review"
  "Major mode for reviewing an agent's plan node-diff.")

(defun valsi-plan-review--refresh ()
  "Redraw the review buffer from `valsi-plan-review--changes'."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "Valsi plan review  [t] toggle  [a] accept-all  [r] reject-all  "
            "[RET] apply  [q] quit\n\n")
    (dolist (row valsi-plan-review--changes)
      (insert (format "  [%s] %s\n" (if (cdr row) "x" " ")
                      (valsi-plan-review--kind-label (car row)))))
    (goto-char (point-min))
    (forward-line 2)))

(defun valsi-plan-review-toggle ()
  "Toggle acceptance of the change on the current line."
  (interactive)
  (let ((i (- (line-number-at-pos) 3)))
    (when (and (>= i 0) (< i (length valsi-plan-review--changes)))
      (let ((row (nth i valsi-plan-review--changes)))
        (setcdr row (not (cdr row))))
      (valsi-plan-review--refresh)
      (forward-line (+ 2 i)))))

(defun valsi-plan-review-accept-all ()
  "Mark every change accepted."
  (interactive)
  (dolist (row valsi-plan-review--changes) (setcdr row t))
  (valsi-plan-review--refresh))

(defun valsi-plan-review-reject-all ()
  "Mark every change rejected."
  (interactive)
  (dolist (row valsi-plan-review--changes) (setcdr row nil))
  (valsi-plan-review--refresh))

(defun valsi-plan-review-apply ()
  "Apply the accepted changes to the target buffer and close the review."
  (interactive)
  (let* ((accepted (delq nil (mapcar (lambda (row) (and (cdr row) (car row)))
                                     valsi-plan-review--changes)))
         (result (valsi-plan-apply-changes valsi-plan-review--old accepted))
         (target valsi-plan-review--target))
    (when (buffer-live-p target)
      (with-current-buffer target
        (let ((pt (point)))
          (erase-buffer)
          (insert result)
          (goto-char (min pt (point-max))))))
    (quit-window)
    (message "Valsi review: applied %d change(s)" (length accepted))))

(provide 'valsi-plan-review)
;;; valsi-plan-review.el ends here

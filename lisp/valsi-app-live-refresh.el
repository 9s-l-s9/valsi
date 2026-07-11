;;; valsi-app-live-refresh.el --- Live artifact reconciliation for Valsi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This module keeps filesystem observation and change reconciliation separate
;; from the project-hub renderer.  A hub subscribes with
;; `valsi-app-live-refresh-subscribe' and passes each fresh scan through
;; `valsi-app-live-refresh-reconcile'.  Filesystem notifications are merely a
;; latency optimization: each reconciliation compares disk signatures with the
;; last authoritative snapshot.

;;; Code:

(require 'cl-lib)
(require 'filenotify)
(require 'seq)
(require 'subr-x)

(defgroup valsi-app-live-refresh nil
  "Live refresh and reconciliation for the Valsi project application."
  :group 'valsi-app)

(defcustom valsi-app-live-refresh-delay 0.35
  "Idle seconds used to coalesce artifact and filesystem changes."
  :type 'number
  :group 'valsi-app-live-refresh)

(cl-defstruct (valsi-app-live-refresh--project
               (:constructor valsi-app-live-refresh--make-project))
  root
  initialized
  signatures
  known
  subscribers
  watches
  timer)

(defvar valsi-app-live-refresh--projects (make-hash-table :test #'equal)
  "Canonical project roots mapped to live-refresh state.")

(defvar-local valsi-app-live-refresh--buffer-root nil
  "Canonical project root whose hub observes this artifact buffer.")

(defvar valsi-app-live-refresh--find-file-hook-installed nil
  "Non-nil when live-refresh discovery is installed in `find-file-hook'.")

(defun valsi-app-live-refresh--canonical-root (root)
  "Return canonical directory form of ROOT."
  (file-name-as-directory (file-truename root)))

(defun valsi-app-live-refresh--project (root)
  "Return or create live-refresh state for ROOT."
  (let* ((root (valsi-app-live-refresh--canonical-root root))
         (project (gethash root valsi-app-live-refresh--projects)))
    (or project
        (let ((fresh
               (valsi-app-live-refresh--make-project
                :root root
                :signatures (make-hash-table :test #'equal)
                :known (make-hash-table :test #'equal)
                :subscribers nil
                :watches nil)))
          (puthash root fresh valsi-app-live-refresh--projects)
          fresh))))

(defun valsi-app-live-refresh--signature (file)
  "Return a stable disk signature for FILE, or nil when it is absent."
  (when-let* ((attributes (file-attributes file 'integer)))
    (list (file-attribute-modification-time attributes)
          (file-attribute-size attributes)
          (file-attribute-inode-number attributes)
          (file-attribute-type attributes))))

(defun valsi-app-live-refresh--file-buffer (file)
  "Return the live file-visiting buffer for FILE, if any."
  (let ((buffer (get-file-buffer file)))
    (and (buffer-live-p buffer) buffer)))

(defun valsi-app-live-refresh--disk-diverged-p (buffer)
  "Return non-nil when BUFFER's visited file changed on disk."
  (and buffer
       (with-current-buffer buffer
         (and buffer-file-name
              (file-exists-p buffer-file-name)
              (not (verify-visited-file-modtime buffer))))))

(defun valsi-app-live-refresh--entry-copy-with-state (entry state)
  "Copy ENTRY and replace its display STATE."
  (let ((copy (copy-sequence entry)))
    (plist-put copy :state state)
    copy))

(defun valsi-app-live-refresh--buffer-after-change (&rest _)
  "Schedule refresh after an observed artifact buffer edit."
  (when valsi-app-live-refresh--buffer-root
    (valsi-app-live-refresh-schedule valsi-app-live-refresh--buffer-root)))

(defun valsi-app-live-refresh--buffer-after-save ()
  "Record an observed save and schedule affected hubs."
  (when valsi-app-live-refresh--buffer-root
    (let* ((project
            (valsi-app-live-refresh--project
             valsi-app-live-refresh--buffer-root))
           (file (and buffer-file-name (file-truename buffer-file-name))))
      ;; A save performed by Emacs is already incorporated into the
      ;; authoritative baseline.  It must not be reported as an external
      ;; "changed on disk" event.
      (when file
        (puthash file (valsi-app-live-refresh--signature file)
                 (valsi-app-live-refresh--project-signatures project)))
      (valsi-app-live-refresh-schedule valsi-app-live-refresh--buffer-root))))

(defun valsi-app-live-refresh--observe-buffer (file root)
  "Observe edits and saves in FILE's existing buffer for ROOT."
  (when-let* ((buffer (valsi-app-live-refresh--file-buffer file)))
    (with-current-buffer buffer
      (setq-local valsi-app-live-refresh--buffer-root root)
      (add-hook 'after-change-functions
                #'valsi-app-live-refresh--buffer-after-change nil t)
      (add-hook 'after-save-hook
                #'valsi-app-live-refresh--buffer-after-save nil t))))

(defun valsi-app-live-refresh--find-file ()
  "Observe a newly visited file when an active project already indexes it."
  (when buffer-file-name
    (let ((file (file-truename buffer-file-name)))
      (maphash
       (lambda (root project)
         (when (and (valsi-app-live-refresh--project-subscribers project)
                    (gethash file
                             (valsi-app-live-refresh--project-known project)))
           (valsi-app-live-refresh--observe-buffer file root)))
       valsi-app-live-refresh--projects))))

(defun valsi-app-live-refresh--install-find-file-hook ()
  "Install lazy observation for files visited after a hub was opened."
  (unless valsi-app-live-refresh--find-file-hook-installed
    (add-hook 'find-file-hook #'valsi-app-live-refresh--find-file)
    (setq valsi-app-live-refresh--find-file-hook-installed t)))

(defun valsi-app-live-refresh--maybe-remove-find-file-hook ()
  "Remove lazy file observation when no project has live subscribers."
  (unless
      (let (active)
        (maphash
         (lambda (_root project)
           (when (valsi-app-live-refresh--project-subscribers project)
             (setq active t)))
         valsi-app-live-refresh--projects)
        active)
    (remove-hook 'find-file-hook #'valsi-app-live-refresh--find-file)
    (setq valsi-app-live-refresh--find-file-hook-installed nil)))

(defun valsi-app-live-refresh-reconcile (root entries)
  "Reconcile scanned ENTRIES for ROOT against buffers and disk.

ENTRIES are plists containing at least `:file'.  Returned entries carry one of
the explicit states `clean', `open', `modified', `changed on disk',
`conflict', `new', or `missing'.  Unsaved buffers are inspected but never
reverted or overwritten."
  (let* ((root (valsi-app-live-refresh--canonical-root root))
         (project (valsi-app-live-refresh--project root))
         (signatures (valsi-app-live-refresh--project-signatures project))
         (known (valsi-app-live-refresh--project-known project))
         (initialized (valsi-app-live-refresh--project-initialized project))
         (seen (make-hash-table :test #'equal))
         result)
    (dolist (entry entries)
      (let* ((file (file-truename (plist-get entry :file)))
             (buffer (valsi-app-live-refresh--file-buffer file))
             (signature (valsi-app-live-refresh--signature file))
             (prior (gethash file signatures))
             (prior-entry (gethash file known))
             (modified (and buffer (buffer-modified-p buffer)))
             (diverged (valsi-app-live-refresh--disk-diverged-p buffer))
             (state
              (cond
               ((and modified diverged) "conflict")
               (modified "modified")
               ((and initialized (not prior-entry)) "new")
               ((and initialized prior (not (equal prior signature)))
                "changed on disk")
               (buffer "open")
               (t "clean"))))
        (puthash file t seen)
        (puthash file signature signatures)
        (puthash file (copy-sequence entry) known)
        (valsi-app-live-refresh--observe-buffer file root)
        (push (valsi-app-live-refresh--entry-copy-with-state entry state)
              result)))
    ;; Keep an indexed artifact visible when its target disappeared.  A file
    ;; that still exists but no longer classifies as an artifact is simply
    ;; removed from the index.
    (when initialized
      (maphash
       (lambda (file old-entry)
         (unless (or (gethash file seen) (file-exists-p file))
           (push (valsi-app-live-refresh--entry-copy-with-state
                  old-entry "missing")
                 result)
           (remhash file signatures)))
       known))
    (setf (valsi-app-live-refresh--project-initialized project) t)
    ;; Reconciliation can discover artifacts in nested directories after the
    ;; initial subscription installed the root watch.
    (valsi-app-live-refresh--ensure-watches project)
    (sort result
          (lambda (left right)
            (string< (plist-get left :file) (plist-get right :file))))))

(defun valsi-app-live-refresh--dispatch (project)
  "Refresh all live hub subscribers of PROJECT."
  (setf (valsi-app-live-refresh--project-timer project) nil)
  (let (live)
    (dolist (subscriber (valsi-app-live-refresh--project-subscribers project))
      (pcase-let ((`(,buffer . ,function) subscriber))
        (when (buffer-live-p buffer)
          (push subscriber live)
          (with-current-buffer buffer
            (funcall function)))))
    (setf (valsi-app-live-refresh--project-subscribers project) (nreverse live))))

(defun valsi-app-live-refresh-schedule (root)
  "Schedule one debounced refresh for subscribers of ROOT."
  (let ((project (valsi-app-live-refresh--project root)))
    (when-let* ((timer (valsi-app-live-refresh--project-timer project)))
      (cancel-timer timer))
    (setf (valsi-app-live-refresh--project-timer project)
          (run-with-idle-timer
           valsi-app-live-refresh-delay nil
           #'valsi-app-live-refresh--dispatch project))))

(defun valsi-app-live-refresh--notify (root _event)
  "Schedule ROOT reconciliation for a filesystem notification."
  (valsi-app-live-refresh-schedule root))

(defun valsi-app-live-refresh--watch-directory (project directory)
  "Add a filesystem watch for PROJECT DIRECTORY when supported."
  (unless (or (file-remote-p directory)
              (assoc directory
                     (valsi-app-live-refresh--project-watches project)))
    (condition-case nil
        (let ((descriptor
               (file-notify-add-watch
                directory '(change attribute-change)
                (apply-partially #'valsi-app-live-refresh--notify
                                 (valsi-app-live-refresh--project-root project)))))
          (push (cons directory descriptor)
                (valsi-app-live-refresh--project-watches project)))
      (file-notify-error nil)
      (file-error nil))))

(defun valsi-app-live-refresh--ensure-watches (project)
  "Ensure PROJECT root and known artifact directories are watched."
  (valsi-app-live-refresh--watch-directory
   project (valsi-app-live-refresh--project-root project))
  (maphash
   (lambda (file _entry)
     (valsi-app-live-refresh--watch-directory
      project (file-name-directory file)))
   (valsi-app-live-refresh--project-known project)))

(defun valsi-app-live-refresh-subscribe (buffer root function)
  "Subscribe BUFFER to debounced ROOT refreshes using FUNCTION.

FUNCTION is called with no arguments in BUFFER.  Repeated subscription replaces
the previous callback for that buffer."
  (let* ((project (valsi-app-live-refresh--project root))
         (subscribers
          (seq-remove
           (lambda (subscriber) (eq (car subscriber) buffer))
           (valsi-app-live-refresh--project-subscribers project))))
    (push (cons buffer function) subscribers)
    (setf (valsi-app-live-refresh--project-subscribers project) subscribers)
    (valsi-app-live-refresh--install-find-file-hook)
    (valsi-app-live-refresh--ensure-watches project)))

(defun valsi-app-live-refresh-unsubscribe (buffer root)
  "Remove BUFFER's live refresh subscription for ROOT.

When the final subscriber leaves, cancel timers and filesystem watches while
retaining the authoritative snapshot for the next hub entry."
  (when root
    (let* ((project (valsi-app-live-refresh--project root))
           (subscribers
            (seq-remove
             (lambda (subscriber) (eq (car subscriber) buffer))
             (valsi-app-live-refresh--project-subscribers project))))
      (setf (valsi-app-live-refresh--project-subscribers project) subscribers)
      (unless subscribers
        (when-let* ((timer (valsi-app-live-refresh--project-timer project)))
          (cancel-timer timer)
          (setf (valsi-app-live-refresh--project-timer project) nil))
        (dolist (watch (valsi-app-live-refresh--project-watches project))
          (ignore-errors (file-notify-rm-watch (cdr watch))))
        (setf (valsi-app-live-refresh--project-watches project) nil))
      (valsi-app-live-refresh--maybe-remove-find-file-hook))))

(defun valsi-app-live-refresh-reset (&optional root)
  "Reset live-refresh state for ROOT, or all roots when ROOT is nil.

This is primarily useful for tests and explicit application teardown."
  (let ((roots
         (if root
             (list (valsi-app-live-refresh--canonical-root root))
           (hash-table-keys valsi-app-live-refresh--projects))))
    (dolist (key roots)
      (when-let* ((project (gethash key valsi-app-live-refresh--projects)))
        (when-let* ((timer (valsi-app-live-refresh--project-timer project)))
          (cancel-timer timer))
        (dolist (watch (valsi-app-live-refresh--project-watches project))
          (ignore-errors (file-notify-rm-watch (cdr watch))))
        (remhash key valsi-app-live-refresh--projects)))
    (valsi-app-live-refresh--maybe-remove-find-file-hook)))

(provide 'valsi-app-live-refresh)
;;; valsi-app-live-refresh.el ends here

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
(require 'generator)
(require 'seq)
(require 'subr-x)

(defgroup valsi-app-live-refresh nil
  "Live refresh and reconciliation for the Valsi project application."
  :group 'valsi-app)

(defcustom valsi-app-live-refresh-delay 0.35
  "Idle seconds used to coalesce artifact and filesystem changes."
  :type 'number
  :group 'valsi-app-live-refresh)

(defcustom valsi-app-live-refresh-time-budget 0.01
  "Seconds of project work per timer turn, checked between files.
A single file operation, parser, or project backend call can take longer."
  :type 'number
  :group 'valsi-app-live-refresh)

(defcustom valsi-app-live-refresh-step-limit 32
  "Maximum work steps in one project refresh timer turn."
  :type 'integer
  :group 'valsi-app-live-refresh)

(cl-defstruct (valsi-app-live-refresh--project
               (:constructor valsi-app-live-refresh--make-project))
  root
  initialized
  signatures
  known
  cache
  subscribers
  watches
  changed-files
  rescan
  scan-function
  iterator
  request-token
  snapshot
  status
  timer)

(define-error 'valsi-app-live-refresh-stale "Artifact changed during refresh")

(defvar valsi-app-live-refresh--projects (make-hash-table :test #'equal)
  "Canonical project roots mapped to live-refresh state.")

(defvar valsi-app-live-refresh--snapshots nil
  "Snapshots shared by subscribers during one refresh dispatch.")

(defvar valsi-app-live-refresh-changed-files nil
  "Edited files during an incremental dispatch, or nil for a full scan.
Disk notifications and explicit refreshes always request a full scan.")

(defvar-local valsi-app-live-refresh--buffer-root nil
  "Canonical project root whose hub observes this artifact buffer.")

(defvar-local valsi-app-live-refresh--buffer-tick nil
  "Last observed text modification tick; fontification does not change it.")

(defvar valsi-app-live-refresh--find-file-hook-installed nil
  "Non-nil when live-refresh discovery is installed in `find-file-hook'.")

(defun valsi-app-live-refresh--canonical-root (root)
  "Return canonical directory form of ROOT."
  (file-name-as-directory (file-truename root)))

(defun valsi-app-live-refresh--project (root)
  "Return or create live-refresh state for ROOT."
  (let* ((root (if (gethash root valsi-app-live-refresh--projects)
                   root
                 (valsi-app-live-refresh--canonical-root root)))
         (project (gethash root valsi-app-live-refresh--projects)))
    (or project
        (let ((fresh
               (valsi-app-live-refresh--make-project
                :root root
                :signatures (make-hash-table :test #'equal)
                :known (make-hash-table :test #'equal)
                :cache (make-hash-table :test #'equal)
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
  (when (and valsi-app-live-refresh--buffer-root
             (not (equal valsi-app-live-refresh--buffer-tick
                         (buffer-chars-modified-tick))))
    (setq valsi-app-live-refresh--buffer-tick (buffer-chars-modified-tick))
    (valsi-app-live-refresh-schedule valsi-app-live-refresh--buffer-root
                                      buffer-file-name)))

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

(defun valsi-app-live-refresh--buffer-killed ()
  "Refresh an observed artifact when its visiting buffer is closed."
  (when valsi-app-live-refresh--buffer-root
    (valsi-app-live-refresh-schedule valsi-app-live-refresh--buffer-root
                                     buffer-file-name)))

(defun valsi-app-live-refresh--observe-buffer (file root)
  "Observe edits and saves in FILE's existing buffer for ROOT."
  (when-let* ((buffer (valsi-app-live-refresh--file-buffer file)))
    (with-current-buffer buffer
      (setq-local valsi-app-live-refresh--buffer-root root)
      (setq-local valsi-app-live-refresh--buffer-tick (buffer-chars-modified-tick))
      (add-hook 'after-change-functions
                #'valsi-app-live-refresh--buffer-after-change nil t)
      (add-hook 'after-save-hook
                #'valsi-app-live-refresh--buffer-after-save nil t)
      (add-hook 'kill-buffer-hook
                #'valsi-app-live-refresh--buffer-killed nil t))))

(defun valsi-app-live-refresh--unobserve (root)
  "Detach artifact buffer hooks for ROOT when observation ends."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (equal valsi-app-live-refresh--buffer-root root)
        (remove-hook 'after-change-functions
                     #'valsi-app-live-refresh--buffer-after-change t)
        (remove-hook 'after-save-hook
                     #'valsi-app-live-refresh--buffer-after-save t)
        (remove-hook 'kill-buffer-hook
                     #'valsi-app-live-refresh--buffer-killed t)
        (setq valsi-app-live-refresh--buffer-root nil
              valsi-app-live-refresh--buffer-tick nil)))))

(defun valsi-app-live-refresh--find-file ()
  "Observe a newly visited file when an active project already indexes it."
  (when buffer-file-name
    (let ((file (file-truename buffer-file-name)))
      (maphash
       (lambda (root project)
         (when (and (valsi-app-live-refresh--project-subscribers project)
                    (or (gethash file (valsi-app-live-refresh--project-known project))
                        (and (valsi-app-live-refresh--project-iterator project)
                             (gethash file (valsi-app-live-refresh--project-cache project)))))
           (valsi-app-live-refresh--observe-buffer file root)
           (when (valsi-app-live-refresh--project-iterator project)
             (valsi-app-live-refresh-schedule root file))))
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
Entries carry explicit buffer/disk states.  Unsaved buffers are never
reverted or overwritten.  This synchronous entry point is also useful in tests."
  (iter-do (_step (valsi-app-live-refresh--reconcile-steps root entries))))

(iter-defun valsi-app-live-refresh--reconcile-steps (root entries &optional valid)
  "Reconcile ROOT ENTRIES one file at a time, returning a complete snapshot.
VALID, when supplied, checks that an entry still describes its source revision.
It is also called with nil at commit to check shared grammar/config revisions.
No baseline is committed until all entries pass validation."
  (let* ((project (valsi-app-live-refresh--project root))
         (root (valsi-app-live-refresh--project-root project))
         (signatures (make-hash-table :test #'equal))
         (known (make-hash-table :test #'equal))
         (old-signatures (valsi-app-live-refresh--project-signatures project))
         (old-known (valsi-app-live-refresh--project-known project))
         (initialized (valsi-app-live-refresh--project-initialized project))
         result)
    (dolist (entry entries)
      (let* ((file (file-truename (plist-get entry :file)))
             (buffer (valsi-app-live-refresh--file-buffer file))
             (signature (valsi-app-live-refresh--signature file))
             (prior (gethash file old-signatures))
             (modified (and buffer (buffer-modified-p buffer)))
             (diverged (valsi-app-live-refresh--disk-diverged-p buffer))
             (state
              (cond
               ((and modified diverged) "conflict")
               (modified "modified")
               ((and initialized (not (gethash file old-known))) "new")
               ((and initialized prior (not (equal prior signature)))
                "changed on disk")
               (buffer "open")
               (t "clean"))))
        (puthash file signature signatures)
        (puthash file (copy-sequence entry) known)
        (valsi-app-live-refresh--observe-buffer file root)
        (when (valsi-app-live-refresh--project-subscribers project)
          (valsi-app-live-refresh--watch-directory project (file-name-directory file)))
        (push (valsi-app-live-refresh--entry-copy-with-state entry state) result))
      (iter-yield nil))
    ;; Retain missing artifacts, but forget existing files removed from the index.
    (when initialized
      (dolist (file (hash-table-keys old-known))
        (unless (or (gethash file known) (file-exists-p file))
          (let ((entry (gethash file old-known)))
            (puthash file entry known)
            (push (valsi-app-live-refresh--entry-copy-with-state entry "missing")
                  result)))
        (iter-yield nil)))
    (when valid
      (dolist (entry entries)
        (unless (funcall valid entry)
          (signal 'valsi-app-live-refresh-stale nil))
        (iter-yield nil))
      (unless (funcall valid nil)
        (signal 'valsi-app-live-refresh-stale nil)))
    (setq result (sort result
                       (lambda (left right)
                         (string< (plist-get left :file) (plist-get right :file)))))
    (setf (valsi-app-live-refresh--project-signatures project) signatures
          (valsi-app-live-refresh--project-known project) known
          (valsi-app-live-refresh--project-initialized project) t
          (valsi-app-live-refresh--project-snapshot project) result)
    result))

(defun valsi-app-live-refresh-snapshot (root scan)
  "Return reconciled entries for ROOT using SCAN, shared during dispatch.
SCAN is called with ROOT.  Explicit calls outside a dispatch always reconcile."
  (let ((cached (and valsi-app-live-refresh--snapshots
                     (gethash root valsi-app-live-refresh--snapshots))))
    (if cached
        (cdr cached)
      (let ((entries (valsi-app-live-refresh-reconcile root (funcall scan root))))
        (when valsi-app-live-refresh--snapshots
          (puthash root (cons t entries) valsi-app-live-refresh--snapshots))
        entries))))

(defun valsi-app-live-refresh--publish (project)
  "Notify live PROJECT subscribers of its snapshot and refresh status."
  (let ((valsi-app-live-refresh--snapshots (make-hash-table :test #'equal)))
    (dolist (subscriber (copy-sequence
                         (valsi-app-live-refresh--project-subscribers project)))
      (when (buffer-live-p (car subscriber))
        (with-current-buffer (car subscriber)
          (funcall (cdr subscriber)))))))

(defun valsi-app-live-refresh--cancel-work (project)
  "Cancel PROJECT timers and discard its incomplete iterator."
  (when-let* ((timer (valsi-app-live-refresh--project-timer project)))
    (cancel-timer timer))
  (let ((iterator (valsi-app-live-refresh--project-iterator project)))
    (setf (valsi-app-live-refresh--project-timer project) nil
          (valsi-app-live-refresh--project-iterator project) nil
          (valsi-app-live-refresh--project-request-token project) nil)
    (when iterator (iter-close iterator))))

(defun valsi-app-live-refresh--continue (project iterator)
  "Advance PROJECT ITERATOR within one bounded timer turn."
  (when (and (eq project (gethash (valsi-app-live-refresh--project-root project)
                                 valsi-app-live-refresh--projects))
             (eq iterator (valsi-app-live-refresh--project-iterator project)))
    (setf (valsi-app-live-refresh--project-timer project) nil)
    (let ((deadline (+ (float-time) (max 0 valsi-app-live-refresh-time-budget)))
          (steps 0))
      (condition-case error
          (while (and (eq iterator (valsi-app-live-refresh--project-iterator project))
                      (< steps (max 1 valsi-app-live-refresh-step-limit))
                      (or (= steps 0) (< (float-time) deadline))
                      (not (input-pending-p)))
            (iter-next iterator)
            (cl-incf steps))
        (iter-end-of-sequence
         (when (eq iterator (valsi-app-live-refresh--project-iterator project))
           (setf (valsi-app-live-refresh--project-iterator project) nil
                 (valsi-app-live-refresh--project-status project) nil
                 (valsi-app-live-refresh--project-snapshot project) (cdr error))
           (valsi-app-live-refresh--publish project)))
        (valsi-app-live-refresh-stale
         (valsi-app-live-refresh-schedule
          (valsi-app-live-refresh--project-root project) nil t))
        (error
         (valsi-app-live-refresh--cancel-work project)
         (setf (valsi-app-live-refresh--project-status project)
               (format "Refresh failed: %s" (error-message-string error)))
         (valsi-app-live-refresh--publish project)))
      (when (eq iterator (valsi-app-live-refresh--project-iterator project))
        ;; A positive ordinary timer delay returns to the command loop even
        ;; during one long idle period; another idle timer could fire at once.
        (setf (valsi-app-live-refresh--project-timer project)
              (run-at-time 0.01 nil #'valsi-app-live-refresh--continue
                           project iterator))))))

(defun valsi-app-live-refresh--dispatch (project &optional token)
  "Start one shared refresh for PROJECT's live subscribers.
TOKEN, when supplied by a timer, rejects callbacks from cancelled requests."
  (when (and (eq project (gethash (valsi-app-live-refresh--project-root project)
                                 valsi-app-live-refresh--projects))
             (or (null token)
                 (eq token (valsi-app-live-refresh--project-request-token project))))
    (setf (valsi-app-live-refresh--project-timer project) nil
          (valsi-app-live-refresh--project-request-token project) nil)
    (let ((valsi-app-live-refresh-changed-files
           (unless (valsi-app-live-refresh--project-rescan project)
             (valsi-app-live-refresh--project-changed-files project)))
          (scan (valsi-app-live-refresh--project-scan-function project)))
      (setf (valsi-app-live-refresh--project-changed-files project) nil
            (valsi-app-live-refresh--project-rescan project) nil)
      (if scan
          (let ((iterator (funcall scan (valsi-app-live-refresh--project-root project)
                                   valsi-app-live-refresh-changed-files)))
            (setf (valsi-app-live-refresh--project-iterator project) iterator
                  (valsi-app-live-refresh--project-status project) 'refreshing)
            (valsi-app-live-refresh--publish project)
            (valsi-app-live-refresh--continue project iterator))
        (valsi-app-live-refresh--publish project)))))

(defun valsi-app-live-refresh-schedule (root &optional file immediate)
  "Schedule one debounced refresh for subscribers of ROOT.
FILE identifies a buffer edit; nil requests full filesystem reconciliation.
IMMEDIATE skips the idle debounce for an explicit user refresh."
  (let ((project (valsi-app-live-refresh--project root)))
    ;; A cancelled pass may contain other changes.  Rediscover on restart so
    ;; none of those changes are lost, while still reusing cached parse results.
    (when (valsi-app-live-refresh--project-iterator project)
      (setf (valsi-app-live-refresh--project-rescan project) t))
    (valsi-app-live-refresh--cancel-work project)
    (if file
        (cl-pushnew file (valsi-app-live-refresh--project-changed-files project)
                    :test #'equal)
      (setf (valsi-app-live-refresh--project-rescan project) t))
    (let ((token (list nil)))
      (setf (valsi-app-live-refresh--project-request-token project) token
            (valsi-app-live-refresh--project-status project) 'refreshing
            (valsi-app-live-refresh--project-timer project)
            (if immediate
                (run-at-time 0.01 nil #'valsi-app-live-refresh--dispatch project token)
              (run-with-idle-timer
               valsi-app-live-refresh-delay nil
               #'valsi-app-live-refresh--dispatch project token))))))

(defun valsi-app-live-refresh--notify (root _event)
  "Schedule ROOT reconciliation for a filesystem notification."
  (when-let* ((project (gethash root valsi-app-live-refresh--projects)))
    (when (valsi-app-live-refresh--project-subscribers project)
      (valsi-app-live-refresh-schedule root))))

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

(defun valsi-app-live-refresh-subscribe (buffer root function &optional scan)
  "Subscribe BUFFER to debounced ROOT refreshes using FUNCTION.

FUNCTION is called with no arguments in BUFFER.  Repeated subscription replaces
the previous callback for that buffer.  SCAN, when non-nil, returns an iterator
for (ROOT CHANGED-FILES); callbacks receive its completed snapshot and status."
  (let* ((project (valsi-app-live-refresh--project root))
         (subscribers
          (seq-remove
           (lambda (subscriber) (eq (car subscriber) buffer))
           (valsi-app-live-refresh--project-subscribers project))))
    (push (cons buffer function) subscribers)
    (setf (valsi-app-live-refresh--project-subscribers project) subscribers)
    (valsi-app-live-refresh--install-find-file-hook)
    (when scan (setf (valsi-app-live-refresh--project-scan-function project) scan))
    (valsi-app-live-refresh--watch-directory
     project (valsi-app-live-refresh--project-root project))))

(defun valsi-app-live-refresh-unsubscribe (buffer root)
  "Remove BUFFER's live refresh subscription for ROOT.

When the final subscriber leaves, cancel timers and filesystem watches while
retaining the authoritative snapshot for the next hub entry."
  (when-let* ((root root)
              (project (gethash (valsi-app-live-refresh--canonical-root root)
                                valsi-app-live-refresh--projects)))
    (let ((subscribers
           (seq-remove
            (lambda (subscriber)
              (or (eq (car subscriber) buffer)
                  (not (buffer-live-p (car subscriber)))))
            (valsi-app-live-refresh--project-subscribers project))))
      (setf (valsi-app-live-refresh--project-subscribers project) subscribers)
      (unless subscribers
        (valsi-app-live-refresh--unobserve
         (valsi-app-live-refresh--project-root project))
        (valsi-app-live-refresh--cancel-work project)
        (setf (valsi-app-live-refresh--project-status project) nil)
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
      (valsi-app-live-refresh--unobserve key)
      (when-let* ((project (gethash key valsi-app-live-refresh--projects)))
        (valsi-app-live-refresh--cancel-work project)
        (dolist (watch (valsi-app-live-refresh--project-watches project))
          (ignore-errors (file-notify-rm-watch (cdr watch))))
        (remhash key valsi-app-live-refresh--projects)))
    (valsi-app-live-refresh--maybe-remove-find-file-hook)))

(provide 'valsi-app-live-refresh)
;;; valsi-app-live-refresh.el ends here

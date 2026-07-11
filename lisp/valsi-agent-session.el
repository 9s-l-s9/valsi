;;; valsi-agent-session.el --- Durable JSONL sessions for the Valsi agent core -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Legacy append-only JSONL sessions for the native test/emergency harness.
;; Pi owns all production session history.  Existing `.valsi/sessions/' data is
;; never deleted or imported into Pi; `valsi-agent-session-archive-legacy'
;; provides an explicit, non-destructive archival move.
;;
;; Each line is one entry object: `{"kind":..., ...}'.  Messages carry the
;; provider-neutral transcript; a `branch' entry records a fork point so
;; `review-update' can model a rejected agent turn as a branch not taken.

;;; Code:

(require 'cl-lib)
(require 'json)

(cl-defstruct (valsi-agent-session (:constructor valsi-agent-session-create))
  "A durable agent session.
ID is a string; FILE is the backing JSONL path; ENTRIES is the in-memory list of
entry plists (oldest first)."
  id file (entries nil))

(defun valsi-agent-sessions-dir (&optional root)
  "Return the legacy native sessions directory under ROOT."
  (expand-file-name ".valsi/sessions/" (or root default-directory)))

(defun valsi-agent-session-archive-legacy (&optional root)
  "Archive ROOT's legacy native sessions without changing their contents.
Move `.valsi/sessions/' to a uniquely timestamped directory below
`.valsi/archive/'.  Production Pi sessions and credentials are not inspected.
Signal a user error when no legacy directory exists.  Return the archive path."
  (interactive)
  (let* ((root (file-name-as-directory
                (expand-file-name (or root default-directory))))
         (source (directory-file-name (valsi-agent-sessions-dir root)))
         (archive-root (expand-file-name ".valsi/archive/" root))
         (stamp (format-time-string "%Y%m%dT%H%M%S"))
         (target (expand-file-name (concat "native-sessions-" stamp)
                                   archive-root))
         (suffix 0))
    (unless (file-directory-p source)
      (user-error "No legacy native sessions at %s" source))
    (while (file-exists-p target)
      (setq suffix (1+ suffix)
            target (expand-file-name
                    (format "native-sessions-%s-%d" stamp suffix)
                    archive-root)))
    (make-directory archive-root t)
    (rename-file source target)
    (when (called-interactively-p 'interactive)
      (message "Archived legacy native sessions at %s" target))
    target))

(defun valsi-agent-session-open (&optional id root)
  "Open (creating if needed) session ID under ROOT as a `valsi-agent-session'.
With no ID, mint a timestamped one.  Existing entries are loaded."
  (let* ((id (or id (format-time-string "%Y%m%dT%H%M%S")))
         (dir (valsi-agent-sessions-dir root))
         (file (expand-file-name (concat id ".jsonl") dir)))
    (make-directory dir t)
    (valsi-agent-session-create
     :id id :file file
     :entries (when (file-readable-p file)
                (valsi-agent-session--read-entries file)))))

(defun valsi-agent-session--read-entries (file)
  "Read FILE's JSONL lines into a list of entry plists (oldest first)."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (out)
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (unless (string-empty-p (string-trim line))
            (push (json-parse-string line :object-type 'plist :array-type 'list)
                  out)))
        (forward-line 1))
      (nreverse out))))

(defun valsi-agent-session--write-line (file obj)
  "Append OBJ, JSON-encoded, as one line to FILE (creating dirs)."
  (make-directory (file-name-directory file) t)
  (let ((json (json-serialize obj)))
    (write-region (concat json "\n") nil file 'append 'silent)))

(defun valsi-agent-session-append (session entry)
  "Append ENTRY (a plist) to SESSION, in memory and to its JSONL file.
Returns ENTRY.  A message plist is wrapped as a `message' entry; any plist that
already has a `:kind' is written as-is."
  (let ((obj (if (plist-member entry :kind)
                 entry
               (list :kind "message" :message entry))))
    (setf (valsi-agent-session-entries session)
          (append (valsi-agent-session-entries session) (list obj)))
    (valsi-agent-session--write-line (valsi-agent-session-file session) obj)
    entry))

(defun valsi-agent-session-messages (session)
  "Return SESSION's transcript: the message plists of its `message' entries."
  (delq nil
        (mapcar (lambda (e) (and (equal (plist-get e :kind) "message")
                                 (plist-get e :message)))
                (valsi-agent-session-entries session))))

(defun valsi-agent-session-branch (session &optional label)
  "Record a branch point in SESSION with optional LABEL and return it.
Marks a fork so a rejected agent turn can be modelled as a branch not taken."
  (valsi-agent-session-append
   session (list :kind "branch" :at (length (valsi-agent-session-entries session))
                 :label (or label ""))))

(defun valsi-agent-session-resume (id &optional root)
  "Re-open session ID under ROOT with its entries loaded (an alias for open)."
  (valsi-agent-session-open id root))

(provide 'valsi-agent-session)
;;; valsi-agent-session.el ends here

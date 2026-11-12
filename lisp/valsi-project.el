;;; valsi-project.el --- Working-project identity and membership -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Client-side identity shared by hubs, source views and terminal agents.
;; Only explicit working-set additions persist; merely opening a hub does not
;; write user state.  Project backends remain owned by project.el.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'transient)

(declare-function valsi "valsi-app")

(defgroup valsi-project nil
  "Working projects in the Valsi application."
  :group 'valsi)

(defcustom valsi-project-file (locate-user-emacs-file "valsi-projects.eld")
  "File storing explicitly added project roots, or nil for session-only use."
  :type '(choice (const nil) file)
  :group 'valsi-project)

(defvar valsi-project--roots nil "Project roots opened in this Emacs session.")
(defvar valsi-project--saved-roots nil "Explicitly remembered project roots.")
(defvar valsi-project--loaded nil "Non-nil after reading project declarations.")
(defvar valsi-project--load-error nil "Error preventing safe declaration writes.")
(defvar valsi-project-change-hook nil "Hook run when working-set membership changes.")
(defvar valsi-project-forget-functions nil
  "Functions called with a root after it is removed from the working set.")
(defvar-local valsi-project-root nil "Canonical project identity for this buffer.")

(autoload 'valsi-projects "valsi-projects" nil t)
(autoload 'valsi-project-switch "valsi-projects" nil t)

(transient-define-prefix valsi-project-menu ()
  "Navigate from a source result to its project or other working projects."
  [["Projects"
    ("P" "projects" valsi-projects)
    ("w" "switch project" valsi-project-switch)
    ("c" "project hub" valsi)]])

(defun valsi-project-canonical-root (root)
  "Return canonical directory identity for ROOT."
  (file-name-as-directory (file-truename root)))

(defun valsi-project-label (root)
  "Return a readable and unambiguous label for ROOT."
  (abbreviate-file-name (directory-file-name root)))

(defun valsi-project-buffer-name (kind root)
  "Return a buffer name for view KIND belonging to ROOT."
  (format "*Valsi %s: %s*" kind (valsi-project-label root)))

(defun valsi-project-register (root)
  "Include ROOT in the session working set and return its canonical identity."
  (let ((root (valsi-project-canonical-root root)))
    (unless (member root valsi-project--roots)
      (setq valsi-project--roots (append valsi-project--roots (list root)))
      (run-hooks 'valsi-project-change-hook))
    root))

(defun valsi-project--read ()
  "Return the roots declared in `valsi-project-file', signaling if invalid.
An empty file declares no roots."
  (let* ((text (with-temp-buffer
                 (insert-file-contents valsi-project-file)
                 (buffer-string)))
         (data (if (string-blank-p text)
                   (list :version 1 :roots nil)
                 (car (read-from-string text)))))
    (unless (and (listp data) (eq (plist-get data :version) 1)
                 (proper-list-p (plist-get data :roots))
                 (seq-every-p
                  (lambda (root)
                    (and (stringp root) (file-name-absolute-p root)))
                  (plist-get data :roots)))
      (error "Invalid project declarations"))
    ;; Stored roots are already canonical.  Loading must not connect to
    ;; remote hosts or require a missing mount to be available.
    (delete-dups (mapcar #'file-name-as-directory (plist-get data :roots)))))

(defun valsi-project--load (&optional reload)
  "Read saved project declarations once, without evaluating their contents.
With RELOAD, read them again so a repaired file is accepted."
  (when (or reload (not valsi-project--loaded))
    (setq valsi-project--loaded t
          valsi-project--load-error nil)
    (when valsi-project-file
      (condition-case err
          (setq valsi-project--saved-roots
                (and (file-exists-p valsi-project-file) (valsi-project--read)))
        (error
         (setq valsi-project--load-error (error-message-string err))
         (message "Valsi projects: %s" valsi-project--load-error))))))

(defun valsi-project-roots ()
  "Return session and explicitly remembered roots in stable display order."
  (valsi-project--load)
  (delete-dups (append valsi-project--saved-roots valsi-project--roots)))

(defun valsi-project--save (function)
  "Atomically save remembered roots changed by FUNCTION.
FUNCTION receives the roots currently in the file, so changes another Emacs
made since they were loaded are kept, and returns the roots to save."
  (if (not valsi-project-file)
      (setq valsi-project--saved-roots (funcall function valsi-project--saved-roots))
    (valsi-project--load t)
    (when valsi-project--load-error
      (user-error "Repair %s before saving projects: %s"
                  valsi-project-file valsi-project--load-error))
    (let* ((roots (funcall function valsi-project--saved-roots))
           ;; Write through a symlink, as a managed state file is often one.
           (target (file-chase-links (expand-file-name valsi-project-file)))
           (directory (file-name-directory target))
           (modes (file-modes target))
           temporary)
      (condition-case err
          (unwind-protect
              (progn
                (make-directory directory t)
                (setq temporary (make-temp-file (expand-file-name ".valsi-projects-" directory)))
                (with-temp-file temporary
                  (let ((print-length nil) (print-level nil))
                    (prin1 (list :version 1 :roots roots) (current-buffer))
                    (insert "\n")))
                (when modes (set-file-modes temporary modes))
                (rename-file temporary target t))
            (when (and temporary (file-exists-p temporary))
              (delete-file temporary)))
        (file-error
         (user-error "Cannot save projects to %s: %s"
                     valsi-project-file (error-message-string err))))
      (setq valsi-project--saved-roots roots))))

(defun valsi-project-remember (root)
  "Remember ROOT across sessions and include it in the working set."
  (valsi-project--load)
  (let ((root (valsi-project-register root)))
    ;; The session keeps the root even when it cannot be persisted.
    (valsi-project--save
     (lambda (roots) (delete-dups (append roots (list root)))))
    (run-hooks 'valsi-project-change-hook)
    root))

(defun valsi-project-forget (root)
  "Remove ROOT from the working set without touching its files or buffers."
  (valsi-project--load)
  ;; Known roots match as given, so a remote or missing root is not resolved;
  ;; other spellings resolve to the identity `valsi-project-remember' stored.
  (setq root (file-name-as-directory root))
  (unless (member root (valsi-project-roots))
    (setq root (valsi-project-canonical-root root)))
  ;; A session-only root never touches the state file.
  (when (member root valsi-project--saved-roots)
    (valsi-project--save (lambda (roots) (delete root (copy-sequence roots)))))
  (setq valsi-project--roots (delete root valsi-project--roots))
  (run-hook-with-args 'valsi-project-forget-functions root)
  (run-hooks 'valsi-project-change-hook))

(defun valsi-project-current-root ()
  "Return current buffer's project identity, or nil outside a project."
  (or valsi-project-root
      (when-let* ((project (project-current nil)))
        (valsi-project-canonical-root (project-root project)))))

(provide 'valsi-project)
;;; valsi-project.el ends here

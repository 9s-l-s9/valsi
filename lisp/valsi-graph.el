;;; valsi-graph.el --- Cross-artifact link graph for Valsi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The thesis capstone: unify the per-family links into a single navigable edge
;; list across the whole project --
;;
;;   instruction  @imports
;;   memory       [[wiki]] links + index pointers
;;   plan         path/trace refs + phase-successor (## Sprint/Phase ordering)
;;
;; An edge is a (SRC KIND TARGET) triple; the driver tags each with the file it
;; came from so the view can navigate.  The edge sources are **pluggable**: a
;; family registers one with `valsi-graph-register-edge-source' and its edges join
;; the graph with no change to the core -- the extension point future families
;; (ADR supersedes, handoff chains, commit/PR issue-refs, changelog provenance,
;; journal->memory promotion) hang off of.

;;; Code:

(require 'cl-lib)
(require 'valsi-view)
(require 'valsi-parse)

(declare-function project-current "project")
(declare-function project-root "project")

(defvar valsi-graph-edge-sources
  '(valsi-graph--edges-instruction
    valsi-graph--edges-memory
    valsi-graph--edges-plan
    valsi-graph--edges-phase)
  "List of edge-source functions.
Each is called with a FILE path and returns a list of (SRC KIND TARGET)
edges.  Extend it with `valsi-graph-register-edge-source' -- the pluggable
seam that lets later families add edges without touching the core.")

;;;###autoload
(defun valsi-graph-register-edge-source (fn)
  "Register FN as a cross-artifact edge source.
FN receives a FILE path and returns a list of (SRC KIND TARGET) edge triples.
Idempotent: registering the same function twice is a no-op.  Returns FN."
  (cl-pushnew fn valsi-graph-edge-sources)
  fn)

(defun valsi-graph--project-root ()
  "Return the project root, or `default-directory'."
  (or (and (fboundp 'project-current) (project-current)
           (project-root (project-current)))
      default-directory))

(defvar valsi-graph-ignored-directories
  '(".git" ".hg" ".svn" ".bzr" "_darcs" ".jj" "node_modules" "references")
  "Directory names the artifact scan never descends into.
Nested repositories and Git worktrees (directories holding a `.git'
entry) are skipped as well, so their copies do not duplicate edges.")

(defvar valsi-graph--root nil
  "Project root bound by `valsi-graph--collect' for edge-source names.")

(defun valsi-graph--descend-p (dir)
  "Return non-nil when the artifact scan should descend into DIR."
  (not (or (member (file-name-nondirectory (directory-file-name dir))
                   valsi-graph-ignored-directories)
           (file-exists-p (expand-file-name ".git" dir)))))

(defun valsi-graph--artifact-files ()
  "Return candidate artifact files under the project root, recursively."
  (ignore-errors
    (directory-files-recursively (valsi-graph--project-root) "\\.md\\'"
                                 nil #'valsi-graph--descend-p)))

(defun valsi-graph--source-name (file)
  "Return the edge SRC for FILE.
Relative to the project root during a collect, so two README.md files
stay distinct; the bare file name otherwise."
  (if valsi-graph--root
      (file-relative-name file valsi-graph--root)
    (file-name-nondirectory file)))

;;;; Built-in edge sources

(defun valsi-graph--edges-instruction (file)
  "Extract @import edges from FILE."
  (let (edges (base (valsi-graph--source-name file)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*@\\([^ \t\n]+\\)" nil t)
        (push (list base "import" (match-string 1)) edges)))
    (nreverse edges)))

(defun valsi-graph--edges-memory (file)
  "Extract [[wiki]] and index-pointer edges from FILE."
  (let (edges (base (valsi-graph--source-name file)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[\\([^]]+\\)\\]\\]" nil t)
        (push (list base "link" (match-string 1)) edges))
      (goto-char (point-min))
      (while (re-search-forward
              "^[ \t]*-[ \t]+\\[[^]]+\\](\\([^)]+\\.md\\))" nil t)
        (push (list base "index" (match-string 1)) edges)))
    (nreverse edges)))

(defun valsi-graph--edges-plan (file)
  "Extract trace/path-ref edges from a plan FILE."
  (let (edges (base (valsi-graph--source-name file)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward "`\\([^`\n]*?/[^`\n]*?\\)`" nil t)
        (push (list base "path" (match-string 1)) edges))
      (goto-char (point-min))
      (while (re-search-forward valsi-parse-req-re nil t)
        (push (list base "trace" (string-trim (match-string 1))) edges)))
    (nreverse edges)))

(defconst valsi-graph-phase-re
  "^##[ \t]+\\(\\(?:Sprint\\|Phase\\|Milestone\\|Stage\\|Part\\)\\b[^\n]*\\)$"
  "Level-2 phase heading recognizer for phase-successor edges.")

(defun valsi-graph--edges-phase (file)
  "Extract phase-successor edges (## Sprint/Phase ordering) from FILE.
Consecutive phase headings yield one \"A → B\" successor edge each."
  (let (titles (base (valsi-graph--source-name file)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward valsi-graph-phase-re nil t)
        (push (string-trim (match-string 1)) titles)))
    (setq titles (nreverse titles))
    (cl-loop for (a b) on titles
             while b
             collect (list base "phase" (format "%s → %s" a b)))))

;;;; Collect + view

(defun valsi-graph--collect ()
  "Return all edges as (FILE SRC KIND TARGET) across the project.
FILE is the absolute path the edge came from (for navigation)."
  (let ((valsi-graph--root (valsi-graph--project-root)) all)
    (dolist (file (valsi-graph--artifact-files))
      (dolist (src valsi-graph-edge-sources)
        (ignore-errors
          (dolist (e (funcall src file))
            (push (cons file e) all)))))
    (nreverse all)))

(defun valsi-graph--entries ()
  "Return tabulated entries for the cross-artifact graph.
The row id is the absolute source file, so RET can visit it."
  (mapcar (lambda (fe)
            (let ((file (car fe)) (e (cdr fe)))
              (list file (vector (nth 0 e) (nth 1 e) (nth 2 e)))))
          (valsi-graph--collect)))

(defun valsi-graph-visit ()
  "Open the artifact file backing the current graph row."
  (interactive)
  (let ((file (tabulated-list-get-id)))
    (if (and file (file-exists-p file))
        (find-file-other-window file)
      (message "No file for this edge"))))

;;;###autoload
(defun valsi-graph ()
  "Show the cross-artifact link graph for the project."
  (interactive)
  (valsi-view-tabulated
   "*Valsi cross-artifact graph*"
   [("Source" 36 t) ("Kind" 8 t) ("Target" 48 t)]
   (valsi-graph--entries)
   #'valsi-graph--entries
   '("Source" . nil))
  (local-set-key (kbd "RET") #'valsi-graph-visit))

(provide 'valsi-graph)
;;; valsi-graph.el ends here

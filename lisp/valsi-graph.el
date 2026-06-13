;;; valsi-graph.el --- Cross-artifact link graph for Valsi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The thesis capstone: unify the per-family links -- instruction @imports,
;; memory [[wiki]] links + index pointers, and plan path/trace refs -- into a
;; single navigable edge list across the whole project.  The edge sources are
;; pluggable so later families can register more without touching the core.

;;; Code:

(require 'cl-lib)
(require 'valsi-view)

(declare-function project-current "project")
(declare-function project-root "project")

(defvar valsi-graph-edge-sources
  '(valsi-graph--edges-instruction
    valsi-graph--edges-memory
    valsi-graph--edges-plan)
  "Functions (FILE) -> list of (SRC KIND TARGET) edges.  Pluggable.")

(defun valsi-graph--project-root ()
  "Return the project root, or `default-directory'."
  (or (and (fboundp 'project-current) (project-current)
           (project-root (project-current)))
      default-directory))

(defun valsi-graph--artifact-files ()
  "Return candidate artifact files under the project root."
  (let ((root (valsi-graph--project-root)) files)
    (dolist (pat '("*.md" "**/*.md"))
      (ignore-errors
        (setq files (append files
                            (file-expand-wildcards
                             (expand-file-name pat root) t)))))
    (cl-remove-if (lambda (f) (string-match-p "/\\(references\\|node_modules\\)/" f))
                  (delete-dups files))))

(defun valsi-graph--edges-instruction (file)
  "Extract @import edges from FILE."
  (let (edges (base (file-name-nondirectory file)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*@\\([^ \t\n]+\\)" nil t)
        (push (list base "import" (match-string 1)) edges)))
    edges))

(defun valsi-graph--edges-memory (file)
  "Extract [[wiki]] and index-pointer edges from FILE."
  (let (edges (base (file-name-nondirectory file)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[\\([^]]+\\)\\]\\]" nil t)
        (push (list base "link" (match-string 1)) edges))
      (goto-char (point-min))
      (while (re-search-forward
              "^[ \t]*-[ \t]+\\[[^]]+\\](\\([^)]+\\.md\\))" nil t)
        (push (list base "index" (match-string 1)) edges)))
    edges))

(defun valsi-graph--edges-plan (file)
  "Extract trace/path-ref edges from a plan FILE."
  (let (edges (base (file-name-nondirectory file)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward "`\\([^`\n]*?/[^`\n]*?\\)`" nil t)
        (push (list base "path" (match-string 1)) edges))
      (goto-char (point-min))
      (while (re-search-forward "_Requirements:[ \t]*\\([0-9., ]+\\)_" nil t)
        (push (list base "trace" (string-trim (match-string 1))) edges)))
    edges))

(defun valsi-graph--collect ()
  "Return all edges across the project as (SRC KIND TARGET) triples."
  (let (all)
    (dolist (file (valsi-graph--artifact-files))
      (dolist (src valsi-graph-edge-sources)
        (ignore-errors
          (setq all (append all (funcall src file))))))
    all))

(defun valsi-graph--entries ()
  "Return tabulated entries for the cross-artifact graph."
  (let ((i 0))
    (mapcar (lambda (e)
              (prog1 (list (number-to-string i)
                           (vector (nth 0 e) (nth 1 e) (nth 2 e)))
                (setq i (1+ i))))
            (valsi-graph--collect))))

;;;###autoload
(defun valsi-graph ()
  "Show the cross-artifact link graph for the project."
  (interactive)
  (valsi-view-tabulated
   "*Valsi cross-artifact graph*"
   [("Source" 34 t) ("Kind" 8 t) ("Target" 50 t)]
   (valsi-graph--entries)
   #'valsi-graph--entries
   '("Source" . nil)))

(provide 'valsi-graph)
;;; valsi-graph.el ends here

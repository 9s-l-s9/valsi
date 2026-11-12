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
(require 'seq)
(require 'subr-x)
(require 'valsi-view)
(require 'valsi-parse)
(require 'valsi-instruction)
(require 'valsi-memory)
(require 'valsi-plan)
(require 'valsi-registry)

(declare-function project-current "project")
(declare-function project-root "project")

(defvar valsi-graph-edge-sources
  '(valsi-graph--edges-instruction
    valsi-graph--edges-memory
    valsi-graph--edges-plan
    valsi-graph--edges-phase)
  "List of edge-source functions, called with a FILE path.
Each source runs in a shared read-only buffer containing that file, returning
triples of the form (SRC KIND TARGET).  Use `valsi-graph-register-edge-source'
to declare
which grammar IDs a source applies to; nil means any grammar.")

(defvar valsi-graph--source-grammars
  '((valsi-graph--edges-instruction instruction)
    (valsi-graph--edges-memory memory)
    (valsi-graph--edges-plan plan)
    (valsi-graph--edges-phase plan))
  "Edge sources and the grammar IDs they accept; absent or nil means any.")

(defvar valsi-graph-current-tree nil
  "The parsed tree shared by edge sources during collection.
Offsets refer to the current buffer's text, starting at zero.")

(defvar valsi-graph-current-grammar nil
  "Detected grammar ID shared by edge sources during collection.")

(defvar valsi-graph--current-file nil "File owning the current shared tree.")
(defvar valsi-graph--errors nil "Failures recorded by the latest graph collection.")

;;;###autoload
(defun valsi-graph-register-edge-source (fn &optional grammars)
  "Register FN for GRAMMARS, a list of grammar IDs, or nil for any grammar.
FN receives a FILE path and returns (SRC KIND TARGET) triples.  It runs in the
shared read-only source buffer and can use `valsi-graph-current-tree' and
`valsi-graph-current-grammar'; it need not reopen FILE.  Existing one-argument
sources remain compatible.  Re-registering updates the grammar declaration
without duplicating FN.  Return FN."
  (unless (and (proper-list-p grammars) (seq-every-p #'symbolp grammars))
    (error "Graph source grammars must be a list of symbols"))
  (cl-pushnew fn valsi-graph-edge-sources)
  (setf (alist-get fn valsi-graph--source-grammars nil nil #'eq) grammars)
  fn)

(defun valsi-graph--project-root ()
  "Return the project root, or `default-directory'."
  (or (and (fboundp 'project-current) (project-current nil)
           (project-root (project-current nil)))
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

(defun valsi-graph--record-error (file source error)
  "Record ERROR from SOURCE at FILE for the graph's visible failure rows."
  (push (list file source (error-message-string error)) valsi-graph--errors))

(defun valsi-graph--artifact-files ()
  "Return candidate files recursively, recording directory read failures."
  (let ((pending (list (valsi-graph--project-root))) files)
    (while pending
      (let ((directory (pop pending)))
        (condition-case err
            (dolist (file (directory-files directory t directory-files-no-dot-files-regexp t))
              (cond
               ((file-directory-p file)
                (when (and (not (file-symlink-p file)) (valsi-graph--descend-p file))
                  (push file pending)))
               ((string-match-p "\\.md\\'" file) (push file files))))
          (file-error (valsi-graph--record-error directory 'discovery err)))))
    (sort files #'string<)))

(defun valsi-graph--source-name (file)
  "Return the edge SRC for FILE.
Relative to the project root during a collect, so two README.md files
stay distinct; the bare file name otherwise."
  (if valsi-graph--root
      (file-relative-name file valsi-graph--root)
    (file-name-nondirectory file)))

;;;; Built-in edge sources

(defun valsi-graph--file-tree (file parser)
  "Return FILE's shared tree or read and parse it directly with PARSER.
The fallback keeps direct calls to individual built-in sources useful."
  (if (equal file valsi-graph--current-file)
      valsi-graph-current-tree
    (with-temp-buffer
      (insert-file-contents file)
      (funcall parser (buffer-string)))))

(defun valsi-graph--edges-instruction (file)
  "Extract import edges from FILE's instruction nodes, excluding fenced code."
  (let ((base (valsi-graph--source-name file)))
    (mapcar (lambda (node) (list base "import" (valsi-node-prop node :target)))
            (valsi-node-of-type
             (valsi-graph--file-tree file #'valsi-instruction-parse) 'import))))

(defun valsi-graph--edges-memory (file)
  "Extract wiki links and index pointers from FILE's memory nodes."
  (let ((base (valsi-graph--source-name file)))
    (mapcar (lambda (node)
              (list base (if (eq (valsi-node-type node) 'link) "link" "index")
                    (valsi-node-prop node :target)))
            (valsi-node-of-type
             (valsi-graph--file-tree file #'valsi-memory-parse) '(link pointer)))))

(defun valsi-graph--edges-plan (file)
  "Extract task file references and requirement traces from plan FILE."
  (let ((base (valsi-graph--source-name file)) edges)
    (dolist (node (valsi-node-of-type
                   (valsi-graph--file-tree file #'valsi-plan-parse) '(task trace)))
      (if (eq (valsi-node-type node) 'trace)
          (push (list base "trace" (string-join (valsi-node-prop node :reqs) ", ")) edges)
        (dolist (ref (valsi-node-prop node :pathrefs))
          (when (valsi-plan--pathref-file ref)
            (push (list base "path" ref) edges)))))
    (nreverse edges)))

(defconst valsi-graph-phase-re
  "\\`\\(?:Sprint\\|Phase\\|Milestone\\|Stage\\|Part\\)\\b"
  "Plan group title recognizer for phase-successor edges.")

(defun valsi-graph--edges-phase (file)
  "Extract successor edges between consecutive level-2 phase groups in FILE."
  (let ((base (valsi-graph--source-name file)) titles)
    (dolist (group (valsi-node-of-type
                    (valsi-graph--file-tree file #'valsi-plan-parse) 'group))
      (when (and (= 2 (valsi-node-prop group :level))
                 (string-match-p valsi-graph-phase-re (valsi-node-prop group :title)))
        (push (valsi-node-prop group :title) titles)))
    (cl-loop for (a b) on (nreverse titles)
             while b collect (list base "phase" (format "%s → %s" a b)))))

;;;; Collect + view

(defun valsi-graph--collect ()
  "Return (FILE SRC KIND TARGET) edges, reading and parsing each file once.
Sources run only for their declared grammar.  Failures are retained in
`valsi-graph--errors' and rendered by `valsi-graph--entries'."
  (unless (valsi-registry-all) (valsi-registry-register-bundled))
  (setq valsi-graph--errors nil)
  (let ((valsi-graph--root (valsi-graph--project-root)) all)
    (dolist (file (condition-case err (valsi-graph--artifact-files)
                    (error (valsi-graph--record-error valsi-graph--root 'discovery err) nil)))
      (condition-case err
          (with-temp-buffer
            (insert-file-contents file)
            (setq buffer-file-name file
                  default-directory (file-name-directory file))
            (let* ((text (buffer-string))
                   (valsi-graph--current-file file)
                   (valsi-graph-current-grammar (valsi-registry-detect file text))
                   (sources
                    (seq-filter
                     (lambda (source)
                       (let ((grammars (alist-get source valsi-graph--source-grammars nil nil #'eq)))
                         (or (null grammars) (memq valsi-graph-current-grammar grammars))))
                     valsi-graph-edge-sources))
                   (valsi-graph-current-tree
                    (and sources (valsi-registry-parse-content valsi-graph-current-grammar text)))
                   (buffer-read-only t))
              (dolist (source sources)
                (condition-case err
                    (save-excursion
                      (save-restriction
                        (widen)
                        (goto-char (point-min))
                        (dolist (edge (funcall source file))
                          (unless (and (proper-list-p edge) (= 3 (length edge))
                                       (seq-every-p #'stringp edge))
                            (error "Invalid graph edge: %S" edge))
                          (push (cons file edge) all))))
                  (error (valsi-graph--record-error file source err))))))
        (error (valsi-graph--record-error file 'read/parse err))))
    (setq valsi-graph--errors (nreverse valsi-graph--errors))
    (when valsi-graph--errors
      (message "Valsi graph: %d failure(s); see error rows" (length valsi-graph--errors)))
    (nreverse all)))

(defun valsi-graph--entries ()
  "Return edge rows followed by visible error rows for the project graph."
  (let ((edges (valsi-graph--collect)))
    (append
     (mapcar (lambda (edge)
               (list (car edge) (vector (nth 1 edge) (nth 2 edge) (nth 3 edge))))
             edges)
     (mapcar (lambda (failure)
               (list (car failure)
                     (vector (valsi-graph--source-name (car failure)) "error"
                             (format "%s: %s"
                                     (if (symbolp (cadr failure)) (cadr failure)
                                       "custom source")
                                     (caddr failure)))))
             valsi-graph--errors))))

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

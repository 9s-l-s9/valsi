;;; valsi-instruction.el --- Instruction-file grammar plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; AAP grammar plugin for instruction files: AGENTS.md, CLAUDE.md, GEMINI.md,
;; .cursor/rules/*.mdc, .github/instructions/*.  Biggest install base, weakest
;; inherent structure -- the best degradation test.  Recognizes two scope axes
;; (heading location + frontmatter glob predicate), instruction items,
;; imperative emphasis markers, @imports, and [[links]].
;; The grammar is derived from a corpus of real-world examples.
;;
;; Evidence tier: emergent (a convention, not a standard).

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-registry)
(require 'valsi-view)

(declare-function valsi-tree "valsi")

(defconst valsi-instruction-emphasis-re
  "\\_<\\(IMPORTANT\\|YOU MUST\\|MUST NOT\\|MUST\\|NEVER\\|ALWAYS\\|DO NOT\\|CRITICAL\\)\\_>"
  "Imperative-emphasis marker recognizer (R2).")

(defconst valsi-instruction-import-re "^[ \t]*@\\([^ \t\n]+\\)"
  "@import recognizer (R5).")

(defconst valsi-instruction-link-re "\\[\\[\\([^]]+\\)\\]\\]"
  "Wiki [[link]] recognizer (R6).")

(defconst valsi-instruction-frontmatter-re "\\`---[ \t]*\\'"
  "A YAML frontmatter fence line (R4).")

(defconst valsi-instruction-peer-names '("AGENTS.md" "CLAUDE.md" "GEMINI.md")
  "Canonical peer instruction filenames for one-source->many sync.")

;;;; Frontmatter (R4 -- glob-predicate scope)

(defun valsi-instruction--unquote (s)
  "Strip surrounding matching single/double quotes from S."
  (let ((s (string-trim s)))
    (if (and (>= (length s) 2)
             (memq (aref s 0) '(?\" ?'))
             (eq (aref s 0) (aref s (1- (length s)))))
        (substring s 1 -1)
      s)))

(defun valsi-instruction--frontmatter-props (raw-lines)
  "Parse RAW-LINES (frontmatter body strings) into a props plist.
Recognizes `description', `globs'/`applyTo' (inline string or block list),
and `alwaysApply'."
  (let ((desc nil) (globs nil) (apply-to nil) (always nil) (key nil))
    (dolist (line raw-lines)
      (cond
       ((string-match "\\`[ \t]*-[ \t]+\\(.*\\)\\'" line)
        (let ((val (valsi-instruction--unquote (match-string 1 line))))
          (pcase key
            ('globs (push val globs))
            ('apply-to (push val apply-to)))))
       ((string-match "\\`\\([A-Za-z_]+\\)[ \t]*:[ \t]*\\(.*\\)\\'" line)
        (let ((k (downcase (match-string 1 line)))
              (v (string-trim (match-string 2 line))))
          (pcase k
            ("description" (setq desc (valsi-instruction--unquote v) key nil))
            ("globs"
             (setq key 'globs)
             (unless (string-empty-p v)
               (push (valsi-instruction--unquote v) globs)))
            ("applyto"
             (setq key 'apply-to)
             (unless (string-empty-p v)
               (push (valsi-instruction--unquote v) apply-to)))
            ("alwaysapply"
             (setq always (string= (downcase v) "true") key nil))
            (_ (setq key nil)))))))
    (list :description desc
          :globs (nreverse globs)
          :apply-to (nreverse apply-to)
          :always-apply always)))

(defun valsi-instruction--parse-frontmatter (lines)
  "If LINES begins with a YAML frontmatter block, return (NODE . BODY-N).
NODE is a `frontmatter' node; BODY-N is the line index just past the closing
fence.  Returns nil when there is no leading frontmatter."
  (when (and lines
             (string-match-p valsi-instruction-frontmatter-re
                             (valsi-line-text (car lines))))
    (let ((open (car lines)) (raw nil) (closed nil))
      (catch 'done
        (dolist (ln (cdr lines))
          (when (string-match-p valsi-instruction-frontmatter-re
                                (valsi-line-text ln))
            (setq closed ln)
            (throw 'done nil))
          (push (valsi-line-text ln) raw)))
      (when closed
        (cons (valsi-node-create
               :type 'frontmatter
               :beg (valsi-line-beg open) :end (valsi-line-end closed)
               :recognizer 'valsi-instruction-frontmatter
               :props (valsi-instruction--frontmatter-props (nreverse raw)))
              (1+ (valsi-line-n closed)))))))

;;;; Inline links (R6)

(defun valsi-instruction--links (text)
  "Return a list of [[link]] targets in TEXT."
  (let (links (start 0))
    (while (string-match valsi-instruction-link-re text start)
      (push (match-string 1 text) links)
      (setq start (match-end 0)))
    (nreverse links)))

;;;; Parse

(defun valsi-instruction-parse (content)
  "Parse CONTENT (a string) into an offset-based instruction node tree."
  (valsi-parse-in-content content #'valsi-instruction--parse-current))

(defun valsi-instruction--parse-current ()
  "Parse the current buffer into an instruction node tree (buffer positions)."
  (let* ((root (valsi-node-create :type 'instruction
                                 :beg (point-min) :end (point-max)
                                 :recognizer 'valsi-instruction))
         (scope-stack nil)
         (lines (valsi-parse-lines (current-buffer)))
         (fm (valsi-instruction--parse-frontmatter lines))
         (body-n (if fm (cdr fm) 0)))
    (when fm (valsi-node-add-child root (car fm)))
    (dolist (line lines)
      (when (>= (valsi-line-n line) body-n)
        (let* ((text (valsi-line-text line))
               (heading (valsi-parse-heading text)))
          (cond
           (heading
            (let ((s (valsi-node-create
                      :type 'scope
                      :beg (valsi-line-beg line) :end (valsi-line-end line)
                      :recognizer 'valsi-instruction-scope
                      :props (list :level (car heading) :title (cdr heading)))))
              (while (and scope-stack (>= (caar scope-stack) (car heading)))
                (pop scope-stack))
              (if scope-stack
                  (valsi-node-add-child (cdar scope-stack) s)
                (valsi-node-add-child root s))
              (push (cons (car heading) s) scope-stack)))
           ((string-match valsi-instruction-import-re text)
            (valsi-node-add-child
             (if scope-stack (cdar scope-stack) root)
             (valsi-node-create :type 'import
                               :beg (valsi-line-beg line) :end (valsi-line-end line)
                               :recognizer 'valsi-instruction-import
                               :props (list :target (match-string 1 text)))))
           ((valsi-parse-bullet text)
            (let ((rest (cdr (valsi-parse-bullet text))))
              (valsi-node-add-child
               (if scope-stack (cdar scope-stack) root)
               (valsi-node-create
                :type 'item
                :beg (valsi-line-beg line) :end (valsi-line-end line)
                :recognizer 'valsi-instruction-item
                :confidence 'loose
                :props (list :text rest
                             :emphasis (and (string-match-p
                                             valsi-instruction-emphasis-re text)
                                            t)
                             :links (valsi-instruction--links text))))))))))
    root))

;;;; Capabilities

(defun valsi-instruction-capabilities (root)
  "Advertise supported actions for ROOT."
  (let ((caps '(outline narrow info dashboard lint sync scaffold)))
    (when (or (valsi-node-of-type root 'scope)
              (valsi-node-of-type root 'frontmatter))
      (push 'effective caps))
    (when (valsi-node-of-type root 'import)
      (push 'follow caps)
      (push 'graph caps))
    (delete-dups caps)))

;;;; Font-lock

(defvar valsi-instruction-font-lock-keywords
  `((,valsi-instruction-emphasis-re . 'valsi-emphasis-face)
    (,valsi-instruction-import-re 1 'valsi-link-face)
    (,valsi-instruction-link-re 1 'valsi-link-face))
  "Font-lock keywords for instruction files.")

;;;; Effective instructions (R3/R4 -- nearest-wins)

(defun valsi-instruction--scope-path-at (root pos)
  "Return the active heading-scope nodes in ROOT at POS, outermost first."
  (let ((stack nil)
        (scopes (sort (copy-sequence (valsi-node-of-type root 'scope))
                      (lambda (a b) (< (valsi-node-beg a) (valsi-node-beg b))))))
    (dolist (scope scopes)
      (when (<= (valsi-node-beg scope) pos)
        (let ((level (valsi-node-prop scope :level)))
          (while (and stack
                      (>= (valsi-node-prop (car stack) :level) level))
            (pop stack))
          (push scope stack))))
    (nreverse stack)))

(defun valsi-instruction-effective-at-point ()
  "Echo the effective scope path (nearest-wins precedence) at point.
Also reports the frontmatter glob predicate when the file is glob-scoped."
  (interactive)
  (let* ((root (valsi-tree))
         (fm (car (valsi-node-of-type root 'frontmatter)))
         (path (valsi-instruction--scope-path-at root (point))))
    (message "Effective scope: %s%s"
             (if path
                 (mapconcat (lambda (scope) (valsi-node-prop scope :title))
                            path " > ")
               "(document root)")
             (cond
              ((null fm) "")
              ((valsi-node-prop fm :always-apply) "  [applies: always]")
              ((or (valsi-node-prop fm :globs) (valsi-node-prop fm :apply-to))
               (format "  [applies to: %s]"
                       (string-join (append (valsi-node-prop fm :globs)
                                            (valsi-node-prop fm :apply-to))
                                    ", ")))
              (t "")))))

;;;; Imports + import graph (R5)

(defun valsi-instruction-imports ()
  "List the @imports referenced by this file."
  (interactive)
  (let* ((root (valsi-tree))
         (imports (valsi-node-of-type root 'import)))
    (if (null imports)
        (message "No @imports")
      (message "Imports: %s"
               (mapconcat (lambda (n) (valsi-node-prop n :target)) imports ", ")))))

(defun valsi-instruction--imports-of-file (file)
  "Return the @import targets declared in FILE (reading it), or nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let (targets)
        (goto-char (point-min))
        (while (re-search-forward valsi-instruction-import-re nil t)
          (push (match-string-no-properties 1) targets))
        (nreverse targets)))))

(defun valsi-instruction--resolve-import (target base-dir)
  "Resolve import TARGET against BASE-DIR (handles ~ and relative paths)."
  (expand-file-name target base-dir))

(defun valsi-instruction--graph-insert (file depth seen)
  "Insert FILE and its transitive imports at DEPTH; SEEN guards cycles."
  (let* ((exists (file-readable-p file))
         (indent (make-string (* 2 depth) ?\s)))
    (insert (format "%s%s%s\n" indent (abbreviate-file-name file)
                    (if exists "" "  [missing]")))
    (cond
     ((gethash file seen) (insert (format "%s  ... (cycle)\n" indent)))
     ((not exists) nil)
     (t (puthash file t seen)
        (dolist (imp (valsi-instruction--imports-of-file file))
          (valsi-instruction--graph-insert
           (valsi-instruction--resolve-import
            imp (file-name-directory file))
           (1+ depth) seen))))))

(defun valsi-instruction-import-graph ()
  "Show the transitive @import graph rooted at this file."
  (interactive)
  (let ((root-file (or buffer-file-name (user-error "Buffer has no file")))
        (seen (make-hash-table :test 'equal))
        (buf (get-buffer-create "*Valsi import graph*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (valsi-instruction--graph-insert root-file 0 seen)
        (goto-char (point-min))
        (special-mode)))
    (switch-to-buffer buf)))

(defun valsi-instruction-follow ()
  "Follow the @import or [[link]] at point to its file."
  (interactive)
  (save-excursion
    (beginning-of-line)
    (cond
     ((re-search-forward valsi-instruction-import-re (line-end-position) t)
      (let ((f (match-string-no-properties 1)))
        (if (file-exists-p (expand-file-name f)) (find-file-other-window f)
          (message "No such import: %s" f))))
     ((re-search-forward valsi-instruction-link-re (line-end-position) t)
      (message "Link: %s" (match-string-no-properties 1)))
     (t (message "No import/link at point")))))

;;;; Lint (R5 danglers + R4 unscoped frontmatter)

(defun valsi-instruction--lint-collect (root &optional dir)
  "Return (NODE . MESSAGE) lint findings for parse tree ROOT.
Pure over the tree; when DIR is non-nil, also flags @import targets that do not
resolve to a readable file on disk.  Findings: unscoped frontmatter (a glob file
with no globs/applyTo and not alwaysApply) and dangling imports."
  (let ((found nil)
        (fm (car (valsi-node-of-type root 'frontmatter))))
    (when fm
      (unless (or (valsi-node-prop fm :globs)
                  (valsi-node-prop fm :apply-to)
                  (valsi-node-prop fm :always-apply))
        (push (cons fm "frontmatter declares no globs/applyTo scope") found)))
    (when dir
      (dolist (imp (valsi-node-of-type root 'import))
        (let ((target (valsi-node-prop imp :target)))
          (when (and target
                     (not (file-readable-p
                           (valsi-instruction--resolve-import target dir))))
            (push (cons imp (format "dangling @import: %s" target)) found)))))
    (nreverse found)))

(defun valsi-instruction-lint ()
  "Report instruction-file health: dangling imports, unscoped frontmatter."
  (interactive)
  (let* ((root (valsi-tree))
         (dir (and buffer-file-name (file-name-directory buffer-file-name)))
         (findings (valsi-instruction--lint-collect root dir)))
    (if (null findings)
        (message "valsi-instruction: clean")
      (with-current-buffer (get-buffer-create "*Valsi instruction lint*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (dolist (f findings) (insert (cdr f) "\n"))
          (goto-char (point-min))
          (special-mode))
        (switch-to-buffer (current-buffer))))))

;;;; Sync (one source -> many peer targets)

(defconst valsi-instruction-sync-begin
  "<!-- valsi:sync:begin (managed by valsi-instruction; do not edit inside) -->"
  "Opening fence of a managed sync region in a target file.")

(defconst valsi-instruction-sync-end
  "<!-- valsi:sync:end -->"
  "Closing fence of a managed sync region in a target file.")

(defun valsi-instruction--sync-region (source target)
  "Return TARGET content carrying SOURCE in a managed region.
If TARGET already has a managed region it is replaced in place; otherwise the
region is appended.  Pure: no filesystem access.  SOURCE and TARGET are strings.
Content outside the managed region is preserved verbatim."
  (let* ((block (concat valsi-instruction-sync-begin "\n"
                        (string-trim-right source) "\n"
                        valsi-instruction-sync-end))
         (re (concat (regexp-quote valsi-instruction-sync-begin)
                     "\\(?:.\\|\n\\)*?"
                     (regexp-quote valsi-instruction-sync-end))))
    (if (string-match re target)
        (replace-match block t t target)
      (concat (string-trim-right target)
              (if (string-empty-p (string-trim target)) "" "\n\n")
              block "\n"))))

(defun valsi-instruction--peer-targets (src-file)
  "Return absolute peer target paths in SRC-FILE's directory (excluding it)."
  (let ((dir (file-name-directory src-file))
        (src-name (file-name-nondirectory src-file)))
    (mapcar (lambda (n) (expand-file-name n dir))
            (remove src-name valsi-instruction-peer-names))))

(defun valsi-instruction-sync ()
  "Sync this instruction file into peer targets' managed regions.
This file is the source; each chosen sibling target gets a managed region
mirroring it, preserving the target's own content outside the region."
  (interactive)
  (let* ((src-file (or buffer-file-name (user-error "Buffer has no file")))
         (source (buffer-substring-no-properties (point-min) (point-max)))
         (targets (valsi-instruction--peer-targets src-file))
         (names (mapcar #'file-name-nondirectory targets))
         (picked (completing-read-multiple
                  "Sync into peers (comma-separated): "
                  names nil t (string-join names ",")))
         (written 0))
    (dolist (name picked)
      (let* ((path (expand-file-name name (file-name-directory src-file)))
             (old (if (file-readable-p path)
                      (with-temp-buffer (insert-file-contents path)
                                        (buffer-string))
                    ""))
             (new (valsi-instruction--sync-region source old)))
        (when (and (not (string= old new))
                   (y-or-n-p (format "Write %s? " name)))
          (with-temp-buffer (insert new) (write-region nil nil path))
          (cl-incf written))))
    (message "valsi-instruction-sync: updated %d file(s)" written)))

;;;; Scaffold

(defun valsi-instruction--scaffold-template (title)
  "Return a starter instruction-file body titled TITLE."
  (concat "# " title "\n\n"
          "Guidance for coding agents working in this repository.\n\n"
          "## Setup\n\n- \n\n"
          "## Build & test\n\n"
          "- ALWAYS run the test suite before committing.\n\n"
          "## Conventions\n\n- IMPORTANT: \n"))

(defun valsi-instruction-scaffold (file)
  "Scaffold a new instruction FILE from a template."
  (interactive
   (list (read-file-name "Scaffold instruction file: "
                         nil "AGENTS.md" nil "AGENTS.md")))
  (when (or (not (file-exists-p file))
            (y-or-n-p (format "%s exists -- overwrite? " file)))
    (find-file file)
    (when (> (buffer-size) 0) (erase-buffer))
    (insert (valsi-instruction--scaffold-template (file-name-base file)))
    (goto-char (point-min))))

;;;; Dashboard

(defun valsi-instruction--dashboard-entries ()
  "Return tabulated entries: one row per scope with item counts."
  (let* ((root (valsi-tree))
         (scopes (valsi-node-of-type root 'scope)))
    (mapcar
     (lambda (s)
       (let ((items (valsi-node-of-type s 'item)))
         (list (valsi-node-beg s)
               (vector
                (make-string (* 2 (1- (valsi-node-prop s :level 1))) ?\s)
                (valsi-node-prop s :title "")
                (number-to-string (length items))
                (number-to-string
                 (cl-count-if (lambda (i) (valsi-node-prop i :emphasis)) items))))))
     scopes)))

(defun valsi-instruction-dashboard ()
  "Show the scope/instruction map for this instruction file."
  (interactive)
  (valsi-view-tabulated
   "*Valsi instruction map*"
   [("" 6 nil) ("Scope" 44 t) ("Items" 7 t) ("Emph" 6 t)]
   (valsi-instruction--dashboard-entries)
   #'valsi-instruction--dashboard-entries))

;;;; Registration

(defun valsi-instruction-match (uri text)
  "Return a match score for a document URI + TEXT as an instruction file."
  (let ((name (or uri ""))
        (score 0))
    (when (string-match-p
           "\\(AGENTS\\|CLAUDE\\|GEMINI\\|COPILOT\\|CONTRIBUTING\\)\\.md\\'"
           name)
      (cl-incf score 4))
    (when (string-match-p
           "\\.cursor/rules/.*\\.mdc\\'\\|\\.github/instructions/\\|\\.instructions\\.md\\'"
           name)
      (cl-incf score 4))
    (when (string-match-p valsi-instruction-emphasis-re text)
      (cl-incf score 1))
    score))

(defun valsi-instruction-register ()
  "Register the instruction grammar plugin."
  (valsi-registry-register
   (list :id 'instruction
         :name "Instruction (AGENTS/CLAUDE)"
         :evidence 'emergent
         :match #'valsi-instruction-match
         :parse #'valsi-instruction-parse
         :font-lock valsi-instruction-font-lock-keywords
         :capabilities #'valsi-instruction-capabilities
         :commands '((info . valsi-instruction-effective-at-point)
                     (effective . valsi-instruction-effective-at-point)
                     (imports . valsi-instruction-imports)
                     (graph . valsi-instruction-import-graph)
                     (follow . valsi-instruction-follow)
                     (lint . valsi-instruction-lint)
                     (sync . valsi-instruction-sync)
                     (scaffold . valsi-instruction-scaffold)
                     (dashboard . valsi-instruction-dashboard)))))

(provide 'valsi-instruction)
;;; valsi-instruction.el ends here

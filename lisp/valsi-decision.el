;;; valsi-decision.el --- Decision (ADR) grammar plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; AAP grammar plugin for Architecture Decision Records (Nygard / MADR).
;;
;; Evidence tier: standardized (adr.github.io, MADR).  Recognizes the ADR
;; title, the Status value + lifecycle (proposed/accepted/deprecated/
;; superseded) from a `## Status' section, an inline `Status:' line, or MADR
;; frontmatter, and the canonical sections (Context/Decision/Consequences,
;; with MADR's section names as aliases).
;; Provides a status readout, an ADR-directory dashboard, a status editor, and
;; a lint (missing status / sections).

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-registry)
(require 'valsi-view)

(declare-function project-current "project")
(declare-function project-root "project")
(declare-function valsi-tree "valsi")

(defconst valsi-decision-statuses
  '("Proposed" "Accepted" "Rejected" "Deprecated" "Superseded")
  "The ADR status lifecycle values.")

(defconst valsi-decision-status-re
  "^##[ \t]+Status[ \t]*$"
  "Status section heading recognizer.")

(defconst valsi-decision-sections
  '("Context" "Decision" "Consequences")
  "Canonical ADR body sections.")

(defconst valsi-decision-section-aliases
  '(("Context" "Context" "Context and Problem Statement")
    ("Decision" "Decision" "Decision Outcome")
    ("Consequences" "Consequences" "Positive Consequences"
     "Negative Consequences"))
  "Each canonical section followed by the heading titles that name it.
The longer titles are MADR's.")

(defconst valsi-decision-madr-sections
  '("Context and Problem Statement" "Decision Outcome")
  "Headings that mark a MADR record, where Consequences is optional.")

(defconst valsi-decision-frontmatter-re "\\`---[ \t]*\\'"
  "A YAML frontmatter fence line.")

(defconst valsi-decision-status-key-re
  "[ \t]*\\(?:[-+*][ \t]+\\)?[*_]*Status[*_]*[ \t]*:[*_]*[ \t]*\\(.*[^ \t\n]\\)"
  "An inline `Status: VALUE' line or frontmatter `status:' key, unanchored.")

;;;; Parse

(defun valsi-decision-parse (content)
  "Parse CONTENT (a string) into an offset-based ADR node tree."
  (valsi-parse-in-content content #'valsi-decision--parse-current))

(defun valsi-decision--frontmatter-end (lines)
  "Return the closing fence line of a frontmatter block opening LINES, or nil."
  (when (and lines (string-match-p valsi-decision-frontmatter-re
                                   (valsi-line-text (car lines))))
    (cl-find-if (lambda (ln) (string-match-p valsi-decision-frontmatter-re
                                             (valsi-line-text ln)))
                (cdr lines))))

(defun valsi-decision--status-key (text)
  "Return the value of a `Status:' line TEXT (quotes stripped), or nil."
  (let ((case-fold-search t))
    (when (string-match (concat "\\`" valsi-decision-status-key-re) text)
      (let ((v (match-string 1 text)))
        (if (string-match "\\`\\([\"']\\)\\(.*\\)\\1\\'" v)
            (match-string 2 v)
          v)))))

(defun valsi-decision--parse-current ()
  "Parse the current buffer into an ADR node tree (buffer positions).
The status comes from a frontmatter `status:' key (MADR), a `## Status'
section, or an inline `Status:' line before the first section, whichever
appears first."
  (let* ((root (valsi-node-create :type 'decision
                                 :beg (point-min) :end (point-max)
                                 :recognizer 'valsi-decision))
         (lines (valsi-parse-lines (current-buffer)))
         (fm-end (valsi-decision--frontmatter-end lines))
         (in-frontmatter fm-end)
         (in-status nil)
         (in-preamble t))
    (dolist (line lines)
      (let* ((text (valsi-line-text line))
             (heading (and (not in-frontmatter) (valsi-parse-heading text)))
             (key (and (or in-frontmatter in-preamble)
                       (null (valsi-node-prop root :status))
                       (valsi-decision--status-key text))))
        (cond
         ;; Frontmatter (only its status key is read)
         (in-frontmatter
          (when key
            (valsi-node-put root :status (valsi-decision--status-of key)))
          (when (eq line fm-end) (setq in-frontmatter nil)))
         ;; Title (first level-1 heading)
         ((and heading (= 1 (car heading)) (null (valsi-node-prop root :title)))
          (valsi-node-put root :title (cdr heading)))
         ;; Section headings
         (heading
          (setq in-preamble nil)
          (setq in-status (string-match-p valsi-decision-status-re text))
          (valsi-node-add-child
           root (valsi-node-create
                 :type 'section
                 :beg (valsi-line-beg line) :end (valsi-line-end line)
                 :recognizer 'valsi-decision-section
                 :props (list :title (cdr heading)))))
         ;; Status value line (first non-blank after the Status heading)
         ((and in-status (string-match "[^ \t]" text)
               (null (valsi-node-prop root :status)))
          (valsi-node-put root :status (valsi-decision--status-of text))
          (setq in-status nil))
         ;; Inline `Status: Accepted' line before the first section
         ;; (Nygard variant, MADR 2 metadata list)
         (key
          (valsi-node-put root :status (valsi-decision--status-of key))))))
    root))

(defun valsi-decision--canonical-section (title)
  "Return the canonical section named by heading TITLE, or nil."
  (car (cl-find-if (lambda (entry) (member-ignore-case title (cdr entry)))
                   valsi-decision-section-aliases)))

(defconst valsi-decision--status-word-re
  (concat "\\(" (mapconcat #'identity valsi-decision-statuses "\\|") "\\)\\>")
  "A lifecycle word, matched case-insensitively and ending at a word boundary.")

(defun valsi-decision--status-of (text)
  "Extract the ADR status from value-line TEXT.
Prefer a leading lifecycle word, matched case-insensitively and
reported in its canonical spelling, optionally with a `superseded by'
clause; a leading list marker is ignored.  Otherwise fall back to the
whole cleaned line (kept descriptive)."
  (let ((clean (string-trim
                (replace-regexp-in-string
                 "[*_`]" ""
                 (replace-regexp-in-string
                  "\\`[ \t]*\\(?:[-+*]\\|[0-9]+[.)]\\)[ \t]+" "" text))))
        (case-fold-search t))
    (if (string-match
         (concat "\\`" valsi-decision--status-word-re
                 "\\(?:[ \t]+by[ \t]+\\(ADR-?[0-9]+\\|[0-9]+\\)\\)?")
         clean)
        (concat (car (member-ignore-case (match-string 1 clean)
                                         valsi-decision-statuses))
                (if (match-string 2 clean)
                    (format " by %s" (match-string 2 clean)) ""))
      clean)))

(defun valsi-decision--standard-status-p (status)
  "Return non-nil when STATUS is a lifecycle word, optionally with a clause.
The base word is the text before a `by' clause, compared case-insensitively."
  (let ((case-fold-search t))
    (string-match-p (concat "\\`" valsi-decision--status-word-re
                            "\\(?:[ \t]+by[ \t]+.+\\)?\\'")
                    status)))

;;;; Capabilities

(defun valsi-decision-capabilities (root)
  "Advertise supported actions for ROOT."
  (let ((caps '(outline narrow info dashboard lint)))
    (when (valsi-node-prop root :status)
      (push 'set-status caps))
    (delete-dups caps)))

;;;; Font-lock

(defvar valsi-decision-font-lock-keywords
  `((,(concat "^##[ \t]+\\(Status\\|Context\\(?: and Problem Statement\\)?"
              "\\|Decision\\(?: Outcome\\)?\\|Consequences\\)[ \t]*$")
     1 'valsi-story-face)
    (,(concat "\\_<\\("
              (mapconcat #'identity valsi-decision-statuses "\\|")
              "\\)\\_>")
     1 'valsi-id-face)
    ("\\(Superseded by\\|Supersedes\\|Amends\\)[ \t]+\\(ADR-?[0-9]+\\|[0-9]+\\)"
     . 'valsi-trace-face))
  "Font-lock keywords for ADR buffers.")

;;;; Commands

(defun valsi-decision-info ()
  "Echo the ADR title, status, and present sections."
  (interactive)
  (let* ((root (valsi-tree))
         (sections (mapcar (lambda (s) (valsi-node-prop s :title))
                           (valsi-node-of-type root 'section))))
    (message "ADR: %s [status: %s] sections: %s"
             (or (valsi-node-prop root :title) "?")
             (or (valsi-node-prop root :status) "none")
             (mapconcat #'identity sections ", "))))

(defun valsi-decision--set-status-key (status)
  "Replace the value of a `Status:' line before the first section with STATUS.
Covers a frontmatter `status:' key and an inline `Status:' line.  Quotes
around the old value are kept and a lowercase old value (MADR) keeps
STATUS lowercase.  Return non-nil when a value was replaced."
  (let ((case-fold-search t)
        (limit (save-excursion
                 (goto-char (point-min))
                 (and (re-search-forward "^#\\{2,6\\}[ \t]" nil t)
                      (match-beginning 0)))))
    (goto-char (point-min))
    (when (re-search-forward
           (concat "^" valsi-decision-status-key-re) limit t)
      (let* ((beg (match-beginning 1)) (end (match-end 1))
             (old (match-string 1))
             (quoted (string-match-p "\\`\\([\"']\\).*\\1\\'" old)))
        (when quoted (setq beg (1+ beg) end (1- end)))
        (let ((case-fold-search nil))
          (when (string-match-p "\\`[\"']?[[:lower:]]" old)
            (setq status (downcase status))))
        (delete-region beg end)
        (goto-char beg)
        (insert status)
        t))))

(defun valsi-decision-set-status ()
  "Set the ADR status to a chosen lifecycle value, updating the value line.
The value is a frontmatter `status:' key or inline `Status:' line before
the first section, else the first line of the `## Status' section."
  (interactive)
  (let ((status (completing-read "Status: " valsi-decision-statuses nil nil)))
    (save-excursion
      (goto-char (point-min))
      (cond
       ((valsi-decision--set-status-key status)
        (message "ADR status -> %s" status))
       ((progn (goto-char (point-min))
               (re-search-forward valsi-decision-status-re nil t))
        (forward-line 1)
        (while (and (not (eobp)) (looking-at "^[ \t]*$"))
          (forward-line 1))
        ;; Replace only an existing value line; an empty section gets
        ;; a new line so the next heading (or EOF) is left intact.
        (cond
         ((and (eobp) (not (bolp))) (insert "\n\n" status "\n"))
         ((eobp) (insert status "\n"))
         ((looking-at "^#+[ \t]") (insert status "\n\n"))
         (t (delete-region (line-beginning-position) (line-end-position))
            (insert status)))
        (message "ADR status -> %s" status))
       (t (message "No ## Status section found"))))))

(defun valsi-decision-lint ()
  "Lint the ADR: missing status or canonical sections."
  (interactive)
  (let* ((root (valsi-tree))
         (titles (mapcar (lambda (s) (valsi-node-prop s :title))
                         (valsi-node-of-type root 'section)))
         (present (mapcar #'valsi-decision--canonical-section titles))
         (madr (cl-some (lambda (title)
                          (member-ignore-case title valsi-decision-madr-sections))
                        titles))
         (issues nil))
    (unless (valsi-node-prop root :status)
      (push "missing Status value" issues))
    (when (and (valsi-node-prop root :status)
               (not (valsi-decision--standard-status-p
                     (valsi-node-prop root :status))))
      (push (format "non-standard status %S" (valsi-node-prop root :status))
            issues))
    (dolist (s (if madr (remove "Consequences" valsi-decision-sections)
                 valsi-decision-sections))
      (unless (member s present)
        (push (format "missing section: %s" s) issues)))
    (if (null issues)
        (message "Valsi ADR: complete")
      (message "Valsi ADR: %s" (mapconcat #'identity (nreverse issues) "; ")))))

(defconst valsi-decision-dir-re "/\\(?:adr\\|decisions?\\)/\\'"
  "A directory name that holds ADRs.")

(defconst valsi-decision-dirs
  '("doc/adr" "docs/adr" "adr" "doc/decisions" "docs/decisions" "decisions")
  "Project-relative ADR directories, in order of preference.")

(defun valsi-decision--dir ()
  "Return the ADR directory.
Prefer the visited file's own directory when it is an ADR directory, then
the first of `valsi-decision-dirs' under the project, then the visited
file's directory."
  (let ((own (and buffer-file-name (file-name-directory buffer-file-name)))
        (root (or (and (fboundp 'project-current) (project-current)
                       (project-root (project-current)))
                  default-directory)))
    (if (and own (string-match-p valsi-decision-dir-re own))
        own
      (cl-find-if #'file-directory-p
                  (append (mapcar (lambda (d) (expand-file-name d root))
                                  valsi-decision-dirs)
                          (list own))))))

(defun valsi-decision--adr-p (file root)
  "Return non-nil when FILE, parsed as ROOT, is likely an ADR.
README, index, and template files are not; a numbered file name, a
status, or a canonical section is enough."
  (let ((name (file-name-nondirectory file)))
    (and (not (string-match-p "\\`\\(?:readme\\|index\\)\\.\\|template"
                              (downcase name)))
         (or (string-match-p "\\`[0-9]+" name)
             (valsi-node-prop root :status)
             (cl-some (lambda (s) (valsi-decision--canonical-section
                                   (valsi-node-prop s :title)))
                      (valsi-node-of-type root 'section))))))

(defun valsi-decision--dashboard-entries ()
  "Return one tabulated row per ADR file in the ADR directory."
  (let ((dir (valsi-decision--dir)))
    (when dir
      (delq nil
            (mapcar
             (lambda (file)
               (let ((root (valsi-decision-parse
                            (with-temp-buffer (insert-file-contents file)
                                              (buffer-string)))))
                 (when (valsi-decision--adr-p file root)
                   (list file
                         (vector (file-name-nondirectory file)
                                 (or (valsi-node-prop root :title) "?")
                                 (or (valsi-node-prop root :status) "-"))))))
             (directory-files dir t "\\.md\\'"))))))

(defun valsi-decision-dashboard ()
  "Show every ADR in the project's decision directory as a table."
  (interactive)
  (valsi-view-tabulated
   "*Valsi decisions*"
   [("File" 28 t) ("Title" 44 t) ("Status" 14 t)]
   (valsi-decision--dashboard-entries)
   #'valsi-decision--dashboard-entries)
  (local-set-key (kbd "RET") #'valsi-decision--visit))

(defun valsi-decision--visit ()
  "Open the ADR on the current dashboard row."
  (interactive)
  (let ((file (tabulated-list-get-id)))
    (when file (find-file-other-window file))))

;;;; Registration

(defun valsi-decision-match (uri text)
  "Return a match score for a document URI + TEXT as an ADR."
  (let ((name (or uri "")) (score 0))
    (when (string-match-p "/adr/[0-9]*-?.*\\.md\\'\\|/decisions?/.*\\.md\\'" name)
      (cl-incf score 4))
    (when (string-match-p "/\\(doc\\|docs\\)/adr/" name) (cl-incf score 2))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (when (re-search-forward valsi-decision-status-re nil t) (cl-incf score 3))
      (goto-char (point-min))
      (when (re-search-forward
             "^##[ \t]+Context\\(?: and Problem Statement\\)?[ \t]*$" nil t)
        (cl-incf score 1))
      (goto-char (point-min))
      (when (re-search-forward "^##[ \t]+Decision\\(?: Outcome\\)?[ \t]*$" nil t)
        (cl-incf score 1)))
    score))

(defun valsi-decision-register ()
  "Register the decision/ADR grammar plugin."
  (valsi-registry-register
   (list :id 'decision
         :name "Decision (ADR)"
         :evidence 'standardized
         :match #'valsi-decision-match
         :parse #'valsi-decision-parse
         :font-lock valsi-decision-font-lock-keywords
         :capabilities #'valsi-decision-capabilities
         :commands '((info . valsi-decision-info)
                     (toggle . valsi-decision-set-status)
                     (set-status . valsi-decision-set-status)
                     (lint . valsi-decision-lint)
                     (dashboard . valsi-decision-dashboard)))))

(provide 'valsi-decision)
;;; valsi-decision.el ends here

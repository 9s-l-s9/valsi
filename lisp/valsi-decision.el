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
  "[ \t]*\\(?:[-+*][ \t]+\\)?[*_]*Status[*_]*[ \t]*:[*_]*[ \t]*\\(.*\\)$"
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
      (let ((v (string-trim-right (match-string 1 text))))
        (if (string-match "\\`\\([\"']\\)\\(.*\\)\\1\\'" v)
            (match-string 2 v)
          v)))))

(defun valsi-decision--record-status (root line value kind)
  "Record VALUE from LINE in ROOT, with source KIND `key' or `section'."
  (valsi-node-put root :status
                  (unless (string-blank-p value) (valsi-decision--status-of value)))
  (valsi-node-put root :status-line (valsi-line-n line))
  (valsi-node-put root :status-kind kind))

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
                       (null (valsi-node-prop root :status-line))
                       (valsi-decision--status-key text))))
        (cond
         ;; Frontmatter (only its status key is read)
         (in-frontmatter
          (when key
            (valsi-decision--record-status root line key 'key))
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
               (null (valsi-node-prop root :status-line)))
          (valsi-decision--record-status root line text 'section)
          (setq in-status nil))
         ;; Inline `Status: Accepted' line before the first section
         ;; (Nygard variant, MADR 2 metadata list)
         (key
          (valsi-decision--record-status root line key 'key)))))
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
  "Return non-nil for a lifecycle STATUS, with an ADR for Superseded.
Compare case-insensitively; a superseding reference may be a bare number."
  (let ((case-fold-search t))
    (or (member-ignore-case status (remove "Superseded" valsi-decision-statuses))
        (string-match-p "\\`Superseded[ \t]+by[ \t]+\\(?:ADR-?\\)?[0-9]+\\'"
                        status))))

;;;; Capabilities

(defun valsi-decision-capabilities (_root)
  "Advertise actions for decision tree _ROOT, including missing-status repair."
  '(outline narrow info dashboard lint set-status))

;;;; Font-lock

(defvar-local valsi-decision--status-cache nil
  "Cached modification tick and lifecycle word's buffer span.")

(defun valsi-decision--status-matcher (limit)
  "Match the parsed status's lifecycle word before LIMIT, never body prose."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (eq tick (car valsi-decision--status-cache))
      (setq valsi-decision--status-cache
            (cons tick
                  (save-excursion
                    (save-restriction
                      (widen)
                      (let ((root (valsi-decision--parse-current))
                            (case-fold-search t))
                        (when-let* ((line (valsi-node-prop root :status-line)))
                          (goto-char (point-min))
                          (forward-line line)
                          (when (re-search-forward
                                 (concat "\\_<" valsi-decision--status-word-re)
                                 (line-end-position) t)
                            (cons (match-beginning 1) (match-end 1))))))))))
    (when-let* ((span (cdr valsi-decision--status-cache)))
      (when (and (>= (car span) (point)) (<= (cdr span) limit))
        (set-match-data (list (car span) (cdr span) (car span) (cdr span)))
        (goto-char (cdr span))
        t))))

(defvar valsi-decision-font-lock-keywords
  `((,(concat "^##[ \t]+\\(Status\\|Context\\(?: and Problem Statement\\)?"
              "\\|Decision\\(?: Outcome\\)?\\|Consequences\\)[ \t]*$")
     1 'valsi-story-face)
    (valsi-decision--status-matcher 1 'valsi-id-face)
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

(defun valsi-decision--set-status-key (status &optional root)
  "Replace the value of a `Status:' line before the first section with STATUS.
Covers a frontmatter `status:' key and an inline `Status:' line.  Quotes
around the old value are kept and a lowercase old value (MADR) keeps
STATUS lowercase.  ROOT is the parsed tree, or nil to parse it here.
Return non-nil when a value was replaced."
  (let ((case-fold-search t)
        (root (or root (valsi-decision--parse-current))))
    (when (eq (valsi-node-prop root :status-kind) 'key)
      (goto-char (point-min))
      (forward-line (valsi-node-prop root :status-line))
      (re-search-forward (concat "^" valsi-decision-status-key-re) (line-end-position) t)
      (let* ((beg (match-beginning 1))
             (old (string-trim-right (match-string 1)))
             (end (+ beg (length old)))
             (quoted (string-match-p "\\`\\([\"']\\).*\\1\\'" old)))
        (when quoted (setq beg (1+ beg) end (1- end)))
        (let ((case-fold-search nil))
          (when (string-match-p "\\`[\"']?[[:lower:]]" old)
            (setq status (downcase status))))
        (when (and (string-empty-p old)
                   (not (memq (char-before beg) '(?\s ?\t))))
          (setq status (concat " " status)))
        (delete-region beg end)
        (goto-char beg)
        (insert status)
        t))))

(defun valsi-decision--read-status ()
  "Read a lifecycle status and, for Superseded, its replacement ADR number."
  (let* ((completion-ignore-case t)
         (choice (completing-read "Status: " valsi-decision-statuses nil t))
         (status (car (member-ignore-case choice valsi-decision-statuses))))
    (unless status (user-error "Choose a non-empty lifecycle status"))
    (when (equal status "Superseded")
      (let ((number (string-trim (read-string "Superseding ADR number: ")))
            (case-fold-search t))
        (unless (string-match "\\`\\(?:ADR-?\\)?\\([0-9]+\\)\\'" number)
          (user-error "Expected an ADR number, such as 12 or ADR-0012"))
        (setq status (format "Superseded by ADR-%04d"
                             (string-to-number (match-string 1 number))))))
    status))

(defun valsi-decision-set-status ()
  "Set the ADR status to a chosen lifecycle value, updating the value line.
The value is a frontmatter `status:' key or inline `Status:' line before
the first section, else the first line of the `## Status' section.
Create a Status section when absent; Superseded prompts for the replacing ADR."
  (interactive)
  (let ((status (valsi-decision--read-status)))
    (save-excursion
      (save-restriction
        (widen)
        (let* ((root (valsi-decision--parse-current))
               (sections (valsi-node-of-type root 'section))
               (section (cl-find-if
                         (lambda (node) (equal "status"
                                              (downcase (valsi-node-prop node :title))))
                         sections)))
          (cond
           ((valsi-decision--set-status-key status root))
           ((eq (valsi-node-prop root :status-kind) 'section)
            (goto-char (point-min))
            (forward-line (valsi-node-prop root :status-line))
            (delete-region (line-beginning-position) (line-end-position))
            (insert status))
           (section
            (goto-char (valsi-node-beg section))
            (forward-line 1)
            (while (and (not (eobp)) (looking-at "^[ \t]*$"))
              (forward-line 1))
            ;; An empty section gets a new line without deleting its heading.
            (cond
             ((and (eobp) (not (bolp))) (insert "\n\n" status "\n"))
             ((eobp) (insert status "\n"))
             (t (insert status "\n\n"))))
           (t
            (goto-char (if sections (valsi-node-beg (car sections)) (point-max)))
            (unless (bolp) (insert "\n"))
            (insert "\n## Status\n\n" status "\n\n")))
          (message "ADR status -> %s" status))))))

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

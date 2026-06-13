;;; valsi-decision.el --- Decision (ADR) grammar plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; AAP grammar plugin for Architecture Decision Records (Nygard / MADR).
;;
;; Evidence tier: standardized (adr.github.io, MADR).  Recognizes the ADR
;; title, the Status value + lifecycle (proposed/accepted/deprecated/
;; superseded), and the canonical sections (Context/Decision/Consequences).
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

;;;; Parse

(defun valsi-decision-parse (content)
  "Parse CONTENT (a string) into an offset-based ADR node tree."
  (valsi-parse-in-content content #'valsi-decision--parse-current))

(defun valsi-decision--parse-current ()
  "Parse the current buffer into an ADR node tree (buffer positions)."
  (let ((root (valsi-node-create :type 'decision
                                :beg (point-min) :end (point-max)
                                :recognizer 'valsi-decision))
        (in-status nil))
    (dolist (line (valsi-parse-lines (current-buffer)))
      (let* ((text (valsi-line-text line))
             (heading (valsi-parse-heading text)))
        (cond
         ;; Title (first level-1 heading)
         ((and heading (= 1 (car heading)) (null (valsi-node-prop root :title)))
          (valsi-node-put root :title (cdr heading)))
         ;; Section headings
         (heading
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
          (setq in-status nil)))))
    root))

(defun valsi-decision--status-of (text)
  "Extract the ADR status from value-line TEXT.
Prefer a leading lifecycle word (optionally with a `superseded by' clause);
otherwise fall back to the whole cleaned line (kept descriptive)."
  (let ((clean (string-trim (replace-regexp-in-string "[*_`]" "" text))))
    (if (string-match
         (concat "\\`\\(" (mapconcat #'identity valsi-decision-statuses "\\|")
                 "\\)\\(?:[ \t]+by[ \t]+\\(ADR-?[0-9]+\\|[0-9]+\\)\\)?")
         clean)
        (concat (match-string 1 clean)
                (if (match-string 2 clean)
                    (format " by %s" (match-string 2 clean)) ""))
      clean)))

;;;; Capabilities

(defun valsi-decision-capabilities (root)
  "Advertise supported actions for ROOT."
  (let ((caps '(outline narrow info dashboard lint)))
    (when (valsi-node-prop root :status)
      (push 'set-status caps))
    (delete-dups caps)))

;;;; Font-lock

(defvar valsi-decision-font-lock-keywords
  `(("^##[ \t]+\\(Status\\|Context\\|Decision\\|Consequences\\)[ \t]*$"
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

(defun valsi-decision-set-status ()
  "Set the ADR status to a chosen lifecycle value, updating the value line."
  (interactive)
  (let ((status (completing-read "Status: " valsi-decision-statuses nil nil)))
    (save-excursion
      (goto-char (point-min))
      (if (re-search-forward valsi-decision-status-re nil t)
          (progn
            (forward-line 1)
            (while (looking-at "^[ \t]*$") (forward-line 1))
            (delete-region (line-beginning-position) (line-end-position))
            (insert status)
            (message "ADR status -> %s" status))
        (message "No ## Status section found")))))

(defun valsi-decision-lint ()
  "Lint the ADR: missing status or canonical sections."
  (interactive)
  (let* ((root (valsi-tree))
         (titles (mapcar (lambda (s) (valsi-node-prop s :title))
                         (valsi-node-of-type root 'section)))
         (issues nil))
    (unless (valsi-node-prop root :status)
      (push "missing Status value" issues))
    (when (and (valsi-node-prop root :status)
               (not (member (valsi-node-prop root :status)
                            valsi-decision-statuses)))
      (push (format "non-standard status %S" (valsi-node-prop root :status))
            issues))
    (dolist (s valsi-decision-sections)
      (unless (member s titles)
        (push (format "missing section: %s" s) issues)))
    (if (null issues)
        (message "Valsi ADR: complete")
      (message "Valsi ADR: %s" (mapconcat #'identity (nreverse issues) "; ")))))

(defun valsi-decision--dir ()
  "Return the ADR directory, preferring doc/adr under the project."
  (let ((root (or (and (fboundp 'project-current) (project-current)
                       (project-root (project-current)))
                  default-directory)))
    (cl-find-if #'file-directory-p
                (list (expand-file-name "doc/adr" root)
                      (expand-file-name "docs/adr" root)
                      (expand-file-name "adr" root)
                      (and buffer-file-name
                           (file-name-directory buffer-file-name))))))

(defun valsi-decision--dashboard-entries ()
  "Return one tabulated row per ADR file in the ADR directory."
  (let ((dir (valsi-decision--dir)))
    (when dir
      (mapcar
       (lambda (file)
         (let ((root (valsi-decision-parse
                      (with-temp-buffer (insert-file-contents file)
                                        (buffer-string)))))
           (list file
                 (vector (file-name-nondirectory file)
                         (or (valsi-node-prop root :title) "?")
                         (or (valsi-node-prop root :status) "-")))))
       (directory-files dir t "\\.md\\'")))))

(defun valsi-decision-dashboard ()
  "Show every ADR in the project's decision directory as a table."
  (interactive)
  (valsi-view-tabulated
   "*Valsi decisions*"
   [("File" 28 t) ("Title" 44 t) ("Status" 14 t)]
   (valsi-decision--dashboard-entries)
   #'valsi-decision--dashboard-entries)
  (define-key valsi-view-list-mode-map (kbd "RET") #'valsi-decision--visit))

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
      (when (re-search-forward "^##[ \t]+Context[ \t]*$" nil t) (cl-incf score 1))
      (goto-char (point-min))
      (when (re-search-forward "^##[ \t]+Decision[ \t]*$" nil t) (cl-incf score 1)))
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

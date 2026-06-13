;;; valsi-promptfile.el --- Prompt-file grammar plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; AAP grammar plugin for frontmatter-configured prompt files: SKILL.md,
;; subagents, slash-commands.  The one place strict frontmatter validation is
;; native.  Recognizes the leading YAML frontmatter (eager: name/description)
;; and the body (lazy).  Description-as-trigger is linted.
;;
;; Evidence tier: emergent (single-vendor promoted).

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-registry)
(require 'valsi-view)

(declare-function valsi-tree "valsi")

(defconst valsi-promptfile-required-keys '("name" "description")
  "Frontmatter keys expected in a prompt/skill file.")

;;;; Frontmatter scan (operate on the current buffer)

(defun valsi-promptfile--frontmatter-bounds ()
  "Return (BEG . END) positions of the current buffer's YAML frontmatter, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "^---[ \t]*$")
      (let ((beg (point)))
        (forward-line 1)
        (when (re-search-forward "^---[ \t]*$" nil t)
          (cons beg (line-end-position)))))))

(defun valsi-promptfile--parse-frontmatter (beg end)
  "Parse simple KEY: VALUE pairs between BEG and END in the current buffer."
  (save-excursion
    (goto-char beg)
    (forward-line 1)
    (let (pairs)
      (while (< (point) end)
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (when (string-match "^\\([A-Za-z0-9_-]+\\):[ \t]*\\(.*\\)$" line)
            (push (cons (match-string 1 line)
                        (string-trim (match-string 2 line)))
                  pairs)))
        (forward-line 1))
      (nreverse pairs))))

;;;; Parse

(defun valsi-promptfile-parse (content)
  "Parse CONTENT (a string) into an offset-based prompt-file node tree."
  (valsi-parse-in-content content #'valsi-promptfile--parse-current))

(defun valsi-promptfile--parse-current ()
  "Parse the current buffer into a prompt-file node tree (buffer positions)."
  (let ((root (valsi-node-create :type 'promptfile
                                :beg (point-min) :end (point-max)
                                :recognizer 'valsi-promptfile))
        (bounds (valsi-promptfile--frontmatter-bounds)))
    (when bounds
      (let* ((pairs (valsi-promptfile--parse-frontmatter (car bounds) (cdr bounds)))
             (fm (valsi-node-create
                  :type 'frontmatter
                  :beg (car bounds) :end (cdr bounds)
                  :recognizer 'valsi-promptfile-frontmatter
                  :props (list :pairs pairs))))
        (dolist (p pairs)
          (valsi-node-add-child
           fm (valsi-node-create :type 'field
                                :beg (car bounds) :end (cdr bounds)
                                :recognizer 'valsi-promptfile-field
                                :props (list :key (car p) :value (cdr p)))))
        (valsi-node-add-child root fm)))
    ;; body headings as sections
    (dolist (line (valsi-parse-lines (current-buffer)))
      (let ((h (valsi-parse-heading (valsi-line-text line))))
        (when h
          (valsi-node-add-child
           root (valsi-node-create
                 :type 'section
                 :beg (valsi-line-beg line) :end (valsi-line-end line)
                 :recognizer 'valsi-promptfile-section
                 :props (list :level (car h) :title (cdr h)))))))
    root))

;;;; Capabilities

(defun valsi-promptfile-capabilities (root)
  "Advertise supported actions for ROOT."
  (let ((caps '(outline narrow dashboard)))
    (when (valsi-node-of-type root 'frontmatter)
      (setq caps (append caps '(validate info))))
    caps))

;;;; Font-lock

(defvar valsi-promptfile-font-lock-keywords
  `(("^\\([A-Za-z0-9_-]+\\):" 1 'valsi-frontmatter-key-face)
    ("^---[ \t]*$" . 'valsi-meta-face))
  "Font-lock keywords for prompt/skill files.")

;;;; Commands

(defun valsi-promptfile-frontmatter-pairs (&optional root)
  "Return the frontmatter KEY.VALUE alist for ROOT (or the client's tree)."
  (let* ((root (or root (valsi-tree)))
         (fm (car (valsi-node-of-type root 'frontmatter))))
    (and fm (valsi-node-prop fm :pairs))))

(defun valsi-promptfile-validate ()
  "Validate the prompt-file frontmatter: required keys + description length."
  (interactive)
  (let* ((pairs (valsi-promptfile-frontmatter-pairs))
         (issues nil))
    (if (null pairs)
        (setq issues (list "no YAML frontmatter found"))
      (dolist (k valsi-promptfile-required-keys)
        (unless (assoc k pairs)
          (push (format "missing required key: %s" k) issues)))
      (let ((desc (cdr (assoc "description" pairs))))
        (when (and desc (< (length desc) 20))
          (push "description-as-trigger is very short (weak match signal)" issues))
        (when (and desc (> (length desc) 1024))
          (push "description exceeds 1024 chars" issues))))
    (if (null issues)
        (message "Valsi promptfile: valid (%d keys)" (length pairs))
      (with-current-buffer (get-buffer-create "*valsi-promptfile-lint*")
        (erase-buffer)
        (insert "Prompt-file validation:\n\n")
        (dolist (i (nreverse issues)) (insert "  - " i "\n"))
        (special-mode)
        (display-buffer (current-buffer)))
      (message "Valsi promptfile: %d issue(s)" (length issues)))))

(defun valsi-promptfile-info ()
  "Echo the frontmatter fields of this prompt file."
  (interactive)
  (let ((pairs (valsi-promptfile-frontmatter-pairs)))
    (if pairs
        (message "%s" (mapconcat (lambda (p) (format "%s=%s" (car p) (cdr p)))
                                 pairs "  "))
      (message "No frontmatter"))))

(defun valsi-promptfile--dashboard-entries ()
  "Return one tabulated row per frontmatter field."
  (mapcar (lambda (p) (list (car p) (vector (car p) (cdr p))))
          (valsi-promptfile-frontmatter-pairs)))

(defun valsi-promptfile-dashboard ()
  "Show the frontmatter fields of this prompt file as a table."
  (interactive)
  (valsi-view-tabulated
   "*Valsi promptfile*"
   [("Key" 20 t) ("Value" 80 nil)]
   (valsi-promptfile--dashboard-entries)
   #'valsi-promptfile--dashboard-entries))

;;;; Registration

(defun valsi-promptfile-match (uri text)
  "Return a match score for a document URI + TEXT as a prompt/skill file."
  (let ((name (or uri ""))
        (score 0))
    (when (string-match-p "SKILL\\.md\\'" name) (cl-incf score 4))
    (when (string-match-p "\\(agents\\|subagents\\|commands\\|skills\\)/" name)
      (cl-incf score 2))
    (with-temp-buffer
      (insert text)
      (when (valsi-promptfile--frontmatter-bounds)
        (let* ((b (valsi-promptfile--frontmatter-bounds))
               (pairs (valsi-promptfile--parse-frontmatter (car b) (cdr b))))
          (when (assoc "description" pairs) (cl-incf score 3))
          (when (assoc "name" pairs) (cl-incf score 1)))))
    score))

(defun valsi-promptfile-register ()
  "Register the prompt-file grammar plugin."
  (valsi-registry-register
   (list :id 'promptfile
         :name "Prompt-file (SKILL)"
         :evidence 'emergent
         :match #'valsi-promptfile-match
         :parse #'valsi-promptfile-parse
         :font-lock valsi-promptfile-font-lock-keywords
         :capabilities #'valsi-promptfile-capabilities
         :commands '((info . valsi-promptfile-info)
                     (validate . valsi-promptfile-validate)
                     (lint . valsi-promptfile-validate)
                     (dashboard . valsi-promptfile-dashboard)))))

(provide 'valsi-promptfile)
;;; valsi-promptfile.el ends here

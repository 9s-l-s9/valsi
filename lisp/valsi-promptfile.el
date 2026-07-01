;;; valsi-promptfile.el --- Prompt-file grammar plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; AAP grammar plugin for frontmatter-configured prompt files: SKILL.md,
;; subagents (.claude/agents/*.md), and slash-commands (.claude/commands/*.md).
;; This is the one genre with a real, near-mandatory frontmatter schema, so the
;; grammar's value is validation + completion of a known vocabulary -- the
;; opposite end of the ladder from the instruction genre.
;;
;; One grammar, three per-type vocabularies (skill/subagent/command), selected
;; by a pure type discriminator over (uri, frontmatter).  The load-time model is
;; first-class: the frontmatter is `eager' (always in the model's context, the
;; trigger) and the body is `lazy' (loaded only when the trigger fires) -- see
;; the `:disclosure' node prop.  See research/05-promptfile-grammar.md.
;;
;; Evidence tier: emergent (single-vendor conventions, promoted).

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-registry)
(require 'valsi-view)

(declare-function valsi-tree "valsi")

(defvar valsi-promptfile--parse-uri nil
  "The URI of the document being parsed, bound during detection/parse.
Lets the pure parser see the filename for type discrimination.")

;;;; Per-type vocabularies (R3)

(defconst valsi-promptfile-vocab
  '((skill    . (:required ("name" "description")
                 :known ("name" "description" "license" "allowed-tools"
                         "version" "metadata")))
    (subagent . (:required ("name" "description")
                 :known ("name" "description" "tools" "model" "color")))
    (command  . (:required ()
                 :known ("description" "argument-hint" "allowed-tools"
                         "model" "disable-model-invocation")))
    (prompt   . (:required ("name" "description")
                 :known ("name" "description" "license" "allowed-tools"
                         "version" "metadata"))))
  "Per-type frontmatter vocabularies: required + known keys.")

(defconst valsi-promptfile-description-min 20
  "Below this length a `description' is too weak to reliably trigger.")

(defconst valsi-promptfile-description-max 1024
  "Hard cap on a `description' length.")

(defun valsi-promptfile--vocab (type key)
  "Return the KEY entry of TYPE's vocabulary (KEY is :required or :known)."
  (plist-get (alist-get type valsi-promptfile-vocab) key))

(defun valsi-promptfile--type (uri pairs)
  "Discriminate the prompt-file TYPE from URI and frontmatter PAIRS (R3)."
  (let ((name (or uri "")))
    (cond
     ((string-match-p "SKILL\\.md\\'" name) 'skill)
     ((string-match-p "\\(sub\\)?agents/" name) 'subagent)
     ((string-match-p "commands/" name) 'command)
     ((assoc "name" pairs) 'prompt)
     (t 'command))))

;;;; Frontmatter scan

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

;;;; Argument placeholders (R6)

(defconst valsi-promptfile-arg-re "\\$\\(ARGUMENTS\\|[0-9]+\\)\\_>"
  "Command-template argument placeholder recognizer (R6).")

(defun valsi-promptfile--args (text)
  "Return the distinct argument placeholders ($ARGUMENTS, $1 ...) in TEXT."
  (let (args (start 0))
    (while (string-match valsi-promptfile-arg-re text start)
      (cl-pushnew (concat "$" (match-string 1 text)) args :test #'string=)
      (setq start (match-end 0)))
    (nreverse args)))

;;;; Parse

(defun valsi-promptfile-parse (content)
  "Parse CONTENT (a string) into an offset-based prompt-file node tree."
  (valsi-parse-in-content content
                         (lambda () (valsi-promptfile--parse-current content))))

(defun valsi-promptfile--parse-current (content)
  "Parse the current buffer (holding CONTENT) into a prompt-file node tree.
CONTENT is passed for URI-independent type refinement and argument scanning."
  (let* ((bounds (valsi-promptfile--frontmatter-bounds))
         (pairs (and bounds (valsi-promptfile--parse-frontmatter
                             (car bounds) (cdr bounds))))
         (type (valsi-promptfile--type valsi-promptfile--parse-uri pairs))
         (root (valsi-node-create :type 'promptfile
                                 :beg (point-min) :end (point-max)
                                 :recognizer 'valsi-promptfile
                                 :props (list :ptype type))))
    (when bounds
      (let ((fm (valsi-node-create
                 :type 'frontmatter
                 :beg (car bounds) :end (cdr bounds)
                 :recognizer 'valsi-promptfile-frontmatter
                 :props (list :pairs pairs :disclosure 'eager))))
        (dolist (p pairs)
          (valsi-node-add-child
           fm (valsi-node-create
               :type 'field
               :beg (car bounds) :end (cdr bounds)
               :recognizer 'valsi-promptfile-field
               :props (list :key (car p) :value (cdr p)
                            :known (and (member (car p)
                                                (valsi-promptfile--vocab
                                                 type :known))
                                        t)
                            :required (and (member (car p)
                                                   (valsi-promptfile--vocab
                                                    type :required))
                                           t)))))
        (valsi-node-add-child root fm)))
    ;; body headings as (lazily-disclosed) sections
    (dolist (line (valsi-parse-lines (current-buffer)))
      (let ((h (valsi-parse-heading (valsi-line-text line))))
        (when (and h (or (null bounds)
                         (> (valsi-line-beg line) (cdr bounds))))
          (valsi-node-add-child
           root (valsi-node-create
                 :type 'section
                 :beg (valsi-line-beg line) :end (valsi-line-end line)
                 :recognizer 'valsi-promptfile-section
                 :props (list :level (car h) :title (cdr h)
                              :disclosure 'lazy))))))
    ;; command argument placeholders anywhere in the body
    (let ((args (valsi-promptfile--args content)))
      (when args
        (valsi-node-put root :args args)))
    root))

;;;; Capabilities

(defun valsi-promptfile-capabilities (root)
  "Advertise supported actions for ROOT."
  (let ((caps '(outline narrow dashboard scaffold)))
    (when (valsi-node-of-type root 'frontmatter)
      (setq caps (append caps '(info validate complete)))
      (when (valsi-promptfile--field root "description")
        (setq caps (append caps '(test-fire)))))
    (delete-dups caps)))

;;;; Font-lock

(defvar valsi-promptfile-font-lock-keywords
  `(("^\\([A-Za-z0-9_-]+\\):" 1 'valsi-frontmatter-key-face)
    ("^---[ \t]*$" . 'valsi-meta-face)
    (,valsi-promptfile-arg-re . 'valsi-id-face))
  "Font-lock keywords for prompt/skill files.")

;;;; Accessors

(defun valsi-promptfile--root (&optional root)
  "Return ROOT or the client's current tree."
  (or root (valsi-tree)))

(defun valsi-promptfile-type (&optional root)
  "Return the prompt-file type symbol for ROOT."
  (valsi-node-prop (valsi-promptfile--root root) :ptype 'command))

(defun valsi-promptfile-frontmatter-pairs (&optional root)
  "Return the frontmatter KEY.VALUE alist for ROOT (or the client's tree)."
  (let ((fm (car (valsi-node-of-type (valsi-promptfile--root root) 'frontmatter))))
    (and fm (valsi-node-prop fm :pairs))))

(defun valsi-promptfile--field (root key)
  "Return the frontmatter value for KEY in ROOT, or nil."
  (cdr (assoc key (valsi-promptfile-frontmatter-pairs root))))

;;;; Validation (rung 3)

(defun valsi-promptfile--validate-collect (root)
  "Return a list of validation issue strings for ROOT.
Pure over the tree.  Checks per-type required keys, unknown keys (warning),
and the description-as-trigger heuristics."
  (let* ((type (valsi-promptfile-type root))
         (pairs (valsi-promptfile-frontmatter-pairs root))
         (issues nil))
    (cond
     ((and (null pairs) (memq type '(skill subagent prompt)))
      (push (format "%s file has no YAML frontmatter" type) issues))
     (pairs
      (dolist (k (valsi-promptfile--vocab type :required))
        (unless (assoc k pairs)
          (push (format "missing required key: %s" k) issues)))
      (dolist (p pairs)
        (unless (member (car p) (valsi-promptfile--vocab type :known))
          (push (format "unknown key for %s: %s (warning)" type (car p))
                issues)))
      (let ((desc (cdr (assoc "description" pairs)))
            (name (cdr (assoc "name" pairs))))
        (when desc
          (when (< (length desc) valsi-promptfile-description-min)
            (push "description-as-trigger is very short (weak match signal)"
                  issues))
          (when (> (length desc) valsi-promptfile-description-max)
            (push (format "description exceeds %d chars"
                          valsi-promptfile-description-max)
                  issues))
          (when (and name (string= (downcase desc) (downcase name)))
            (push "description merely restates name (weak trigger)" issues))))))
    (nreverse issues)))

(defun valsi-promptfile-validate ()
  "Validate the prompt-file frontmatter against its per-type vocabulary."
  (interactive)
  (let ((issues (valsi-promptfile--validate-collect (valsi-tree)))
        (type (valsi-promptfile-type)))
    (if (null issues)
        (message "valsi-promptfile: valid %s" type)
      (with-current-buffer (get-buffer-create "*valsi-promptfile-lint*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Prompt-file validation (%s):\n\n" type))
          (dolist (i issues) (insert "  - " i "\n"))
          (goto-char (point-min))
          (special-mode))
        (display-buffer (current-buffer)))
      (message "valsi-promptfile: %d issue(s)" (length issues)))))

;;;; Key completion (rung 3)

(defun valsi-promptfile-complete-key ()
  "Insert a known frontmatter key not yet present, for this file's type.
Completes over the vocabulary's known keys minus those already declared."
  (interactive)
  (let* ((root (valsi-tree))
         (type (valsi-promptfile-type root))
         (present (mapcar #'car (valsi-promptfile-frontmatter-pairs root)))
         (missing (cl-remove-if (lambda (k) (member k present))
                                (valsi-promptfile--vocab type :known)))
         (fm (car (valsi-node-of-type root 'frontmatter))))
    (unless fm (user-error "No frontmatter to complete into"))
    (unless missing (user-error "All known %s keys already present" type))
    (let ((key (completing-read (format "Add %s key: " type) missing nil t)))
      (goto-char (valsi-node-end fm))
      (beginning-of-line)
      (insert key ": \n")
      (forward-char -1))))

;;;; Description-as-trigger test-fire (rung 4)

(defun valsi-promptfile--tokenize (s)
  "Return the set of lowercased word tokens (length >= 3) in S."
  (delete-dups
   (cl-remove-if (lambda (w) (< (length w) 3))
                 (split-string (downcase (or s "")) "[^a-z0-9]+" t))))

(defun valsi-promptfile--match-score (description query)
  "Return the fraction of QUERY tokens that appear in DESCRIPTION (0.0-1.0)."
  (let* ((qtokens (valsi-promptfile--tokenize query))
         (dtokens (valsi-promptfile--tokenize description)))
    (if (null qtokens) 0.0
      (/ (float (cl-count-if (lambda (q) (member q dtokens)) qtokens))
         (length qtokens)))))

(defun valsi-promptfile-test-fire (query)
  "Test whether this prompt's description would trigger on QUERY.
A naive keyword-overlap heuristic over description-as-trigger: it reports the
fraction of QUERY's content words the description covers.  This is a design aid,
not the real matcher -- it answers \"would this prompt plausibly match?\""
  (interactive "sCandidate query/task: ")
  (let ((desc (valsi-promptfile--field (valsi-tree) "description")))
    (if (null desc)
        (message "No description to match against")
      (let ((score (valsi-promptfile--match-score desc query)))
        (message "Match score %.0f%% -- %s"
                 (* 100 score)
                 (cond ((>= score 0.5) "would likely trigger")
                       ((> score 0.0) "weak / partial match")
                       (t "would NOT trigger (no shared terms)")))))))

;;;; Info / dashboard

(defun valsi-promptfile-info ()
  "Echo the type + frontmatter fields of this prompt file."
  (interactive)
  (let ((pairs (valsi-promptfile-frontmatter-pairs))
        (type (valsi-promptfile-type)))
    (if pairs
        (message "%s: %s" type
                 (mapconcat (lambda (p) (format "%s=%s" (car p) (cdr p)))
                            pairs "  "))
      (message "%s (no frontmatter)" type))))

(defun valsi-promptfile--dashboard-entries ()
  "Return one tabulated row per frontmatter field, flagging unknowns."
  (let ((type (valsi-promptfile-type)))
    (mapcar (lambda (p)
              (let ((known (member (car p)
                                   (valsi-promptfile--vocab type :known)))
                    (req (member (car p)
                                 (valsi-promptfile--vocab type :required))))
                (list (car p)
                      (vector (car p)
                              (cond (req "required") (known "known") (t "?"))
                              (cdr p)))))
            (valsi-promptfile-frontmatter-pairs))))

(defun valsi-promptfile-dashboard ()
  "Show the frontmatter fields of this prompt file as a table."
  (interactive)
  (valsi-view-tabulated
   "*Valsi promptfile*"
   [("Key" 22 t) ("Kind" 10 t) ("Value" 60 nil)]
   (valsi-promptfile--dashboard-entries)
   #'valsi-promptfile--dashboard-entries))

;;;; Scaffold (rung 5 -- a skill directory, not just a file)

(defun valsi-promptfile--skill-template (name)
  "Return a starter SKILL.md body for skill NAME."
  (concat "---\n"
          "name: " name "\n"
          "description: One sentence saying what this does and WHEN to use it"
          " (the trigger).\n"
          "---\n\n"
          "# " (capitalize (replace-regexp-in-string "-" " " name)) "\n\n"
          "Instructions the agent reads only after the description triggers.\n\n"
          "## Steps\n\n"
          "1. \n\n"
          "## References\n\n"
          "- See `references/` for supporting material.\n"))

(defun valsi-promptfile-scaffold (dir)
  "Scaffold a skill directory DIR: SKILL.md + scripts/references/assets."
  (interactive (list (read-directory-name "Scaffold skill directory: ")))
  (let* ((dir (file-name-as-directory dir))
         (name (file-name-nondirectory (directory-file-name dir)))
         (skill (expand-file-name "SKILL.md" dir)))
    (when (or (not (file-exists-p skill))
              (y-or-n-p (format "%s exists -- overwrite SKILL.md? " skill)))
      (make-directory dir t)
      (dolist (sub '("scripts" "references" "assets"))
        (make-directory (expand-file-name sub dir) t))
      (with-temp-buffer
        (insert (valsi-promptfile--skill-template name))
        (write-region nil nil skill))
      (find-file skill)
      (message "Scaffolded skill %s (+ scripts/ references/ assets/)" name))))

;;;; Registration

(defun valsi-promptfile-match (uri text)
  "Return a match score for a document URI + TEXT as a prompt/skill file."
  (let ((name (or uri ""))
        (score 0))
    (when (string-match-p "SKILL\\.md\\'" name) (cl-incf score 5))
    (when (string-match-p "\\(sub\\)?agents/\\|commands/" name)
      (cl-incf score 3))
    (with-temp-buffer
      (insert text)
      (let ((b (valsi-promptfile--frontmatter-bounds)))
        (when b
          (let ((pairs (valsi-promptfile--parse-frontmatter (car b) (cdr b))))
            (when (assoc "description" pairs) (cl-incf score 3))
            (when (assoc "name" pairs) (cl-incf score 1))
            ;; command-specific keys are a strong signal even without name
            (when (or (assoc "argument-hint" pairs)
                      (assoc "allowed-tools" pairs))
              (cl-incf score 2))))))
    score))

(defun valsi-promptfile-detect (uri text)
  "Score URI + TEXT, binding `valsi-promptfile--parse-uri' to URI for the parse.
The `:match' entry point; the side effect lets the pure parser (which only sees
content) discriminate the type by filename during the ensuing parse."
  (setq valsi-promptfile--parse-uri uri)
  (valsi-promptfile-match uri text))

(defun valsi-promptfile-register ()
  "Register the prompt-file grammar plugin."
  (valsi-registry-register
   (list :id 'promptfile
         :name "Prompt-file (SKILL/agent/command)"
         :evidence 'emergent
         :match #'valsi-promptfile-detect
         :parse #'valsi-promptfile-parse
         :font-lock valsi-promptfile-font-lock-keywords
         :capabilities #'valsi-promptfile-capabilities
         :commands '((info . valsi-promptfile-info)
                     (validate . valsi-promptfile-validate)
                     (lint . valsi-promptfile-validate)
                     (complete . valsi-promptfile-complete-key)
                     (test-fire . valsi-promptfile-test-fire)
                     (scaffold . valsi-promptfile-scaffold)
                     (dashboard . valsi-promptfile-dashboard)))))

(provide 'valsi-promptfile)
;;; valsi-promptfile.el ends here

;;; valsi-parse.el --- Shared pure-elisp recognizers for Valsi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Pure-elisp line/block recognizer helpers shared by every grammar plugin.
;; No tree-sitter dependency (see doc/adr/0002).  Recognizers are tolerant:
;; they annotate structure and never signal on unrecognized input.
;;
;; Grammar plugins build their own node trees on top of these primitives via
;; `valsi-parse-lines', which walks the buffer once yielding line records.

;;; Code:

(require 'cl-lib)
(require 'valsi-node)

;;;; Content parsing (the pure boundary)

(defun valsi-parse-in-content (content parse-fn)
  "Parse CONTENT (a string) with PARSE-FN, returning an offset-based node tree.
CONTENT is inserted into a temp buffer and PARSE-FN is called with no
arguments on that buffer (so ordinary buffer recognizers work).  The result
tree's BEG/END are then normalized to 0-based offsets into CONTENT, making the
parse a pure function of text -- independent of any live buffer or point.
This is the seam a wire transport (or a non-Emacs server) plugs into."
  (with-temp-buffer
    (insert content)
    (let* ((valsi-node--child-tails (make-hash-table :test #'eq))
           (tree (funcall parse-fn)))
      ;; temp-buffer positions are 1-based; shift to 0-based content offsets.
      (valsi-node-shift tree (- (point-min)))
      tree)))

;;;; Line records

(cl-defstruct (valsi-line (:constructor valsi-line-create))
  "One physical line of a buffer, with byte region and text."
  n beg end text indent)

(defun valsi-parse-lines (&optional buffer)
  "Return a list of `valsi-line' for every line of BUFFER (or current)."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (goto-char (point-min))
      (let ((n 0) acc)
        (while (not (eobp))
          (let* ((beg (line-beginning-position))
                 (end (line-end-position))
                 (text (buffer-substring-no-properties beg end)))
            (push (valsi-line-create
                   :n n :beg beg :end (min (point-max) (1+ end))
                   :text text
                   :indent (string-match-p "[^ \t]" text))
                  acc))
          (setq n (1+ n))
          (forward-line 1))
        (nreverse acc)))))

;;;; Generic markdown recognizers

(defconst valsi-parse-heading-re "^\\(#\\{1,6\\}\\)[ \t]+\\(.*\\)$"
  "ATX heading recognizer (CommonMark allows at most six hashes).")

(defconst valsi-parse-heading-close-re "\\(?:\\`\\|[ \t]+\\)#+[ \t]*\\'"
  "Optional closing hash sequence of an ATX heading title.")

(defun valsi-parse-heading (text)
  "If TEXT is an ATX heading return (LEVEL . TITLE), else nil.
A closing sequence of hashes (\"## Foo ##\") is not part of TITLE."
  (when (string-match valsi-parse-heading-re text)
    (let ((level (length (match-string 1 text)))
          (title (match-string 2 text)))
      (cons level
            (string-trim
             (replace-regexp-in-string valsi-parse-heading-close-re ""
                                       title t t))))))

(defconst valsi-parse-checkbox-re
  "^\\([ \t]*\\)-[ \t]+\\[\\(.\\)\\][ \t]+\\(.*\\)$"
  "GFM task-list checkbox recognizer (R1).")

(defun valsi-parse-state-char (char)
  "Map a checkbox CHAR (string of length 1) to a state symbol.
Descriptive: unknown chars are surfaced, never rewritten."
  (pcase char
    (" " 'open)
    ((or "x" "X") 'done)
    ((or "-" "~") 'in-progress)
    ("/" 'in-progress)
    ((or "c" "C") 'cancelled)
    (_ 'unknown)))

(defun valsi-parse-checkbox (text)
  "If TEXT is a checkbox line return a plist, else nil.
Plist keys: :indent (columns) :state :char :rest :rest-offset."
  (when (string-match valsi-parse-checkbox-re text)
    (list :indent (length (match-string 1 text))
          :char (match-string 2 text)
          :state (valsi-parse-state-char (match-string 2 text))
          :rest (match-string 3 text)
          :rest-offset (match-beginning 3))))

(defconst valsi-parse-bullet-re "^\\([ \t]*\\)-[ \t]+\\(.*\\)$"
  "Plain list bullet (used for step recognition, R7).")

(defun valsi-parse-bullet (text)
  "If TEXT is a plain (non-checkbox) bullet return (INDENT . REST), else nil."
  (when (and (string-match valsi-parse-bullet-re text)
             (not (valsi-parse-checkbox text)))
    (cons (length (match-string 1 text)) (match-string 2 text))))

;;;; Inline recognizers (operate on a task's rest-text)

(defconst valsi-parse-tag-re "\\[\\([A-Za-z0-9][A-Za-z0-9._-]*\\)\\]"
  "Bracketed tag recognizer (R3): [P], [US1], [label].")

(defconst valsi-parse--lead-id-re
  "[ \t]*\\(?:T[0-9]+\\(?:\\.[0-9]+\\)*\\|[0-9]+\\(?:\\.[0-9]+\\)*\\)\\.?\\(?:[ \t)]\\|\\'\\)"
  "A task id that may sit among the leading tags (cf. `valsi-parse-id-re').")

(defun valsi-parse--match-at (regexp text pos)
  "Return non-nil when REGEXP matches TEXT exactly at POS (match data set)."
  (eq pos (string-match regexp text pos)))

(defun valsi-parse-tags (text)
  "Return a list of (TAG-STRING . KIND) recognized in leading TEXT.
KIND is one of `parallel', `story', `label'.  Also matches bare US1.
Only the leading run of tokens counts: bracketed tags, bare story ids,
and at most one task id (speckit puts it first: \"T001 [P] [US1] do\").
Brackets after the first word of free description (citations, link text)
are not tags."
  (let ((tags nil) (pos 0) (id-seen nil) (done nil))
    (while (not done)
      (cond
       ;; [TAG], but not the text of a markdown link [text](url)
       ((and (valsi-parse--match-at
              (concat "[ \t]*" valsi-parse-tag-re) text pos)
             (not (eq ?\( (aref (concat text " ") (match-end 0)))))
        (let ((tok (match-string 1 text)))
          (push (cons tok (valsi-parse--tag-kind tok)) tags)
          (setq pos (match-end 0))))
       ;; bare story id: US1
       ((valsi-parse--match-at "[ \t]*\\(US[0-9]+\\)\\b" text pos)
        (let ((tok (match-string 1 text)))
          (unless (assoc tok tags)
            (push (cons tok 'story) tags))
          (setq pos (match-end 0))))
       ((and (not id-seen)
             (valsi-parse--match-at valsi-parse--lead-id-re text pos))
        (setq id-seen t
              pos (match-end 0)))
       (t (setq done t))))
    (nreverse tags)))

(defun valsi-parse--tag-kind (tok)
  "Classify tag TOK into a kind symbol."
  (cond ((string= tok "P") 'parallel)
        ((string-match-p "\\`US[0-9]+\\'" tok) 'story)
        (t 'label)))

(defconst valsi-parse-id-re
  "\\`\\(?:\\[[^]]*\\][ \t]*\\)*\\(T[0-9]+\\(?:\\.[0-9]+\\)*\\|[0-9]+\\(?:\\.[0-9]+\\)*\\)\\.?[ \t)]"
  "Leading task-id recognizer (R2): Tnnn, T001.1, or kiro 1 / 1.2.")

(defun valsi-parse-id (text)
  "Return the leading task id string in TEXT (R2), or nil."
  (when (string-match valsi-parse-id-re text)
    (match-string 1 text)))

(defun valsi-parse-sort-key (id)
  "Parse an id string ID into a numeric sort key list.
\"T101\" -> (101), \"1.2\" -> (1 2), nil/garbage -> nil."
  (when (and id (string-match "\\([0-9.]+\\)" id))
    (mapcar #'string-to-number
            (split-string (match-string 1 id) "\\." t))))

(defun valsi-parse-sort-key< (a b)
  "Return non-nil when sort key A precedes B."
  (cond ((and (null a) (null b)) nil)
        ((null a) t)
        ((null b) nil)
        ((= (car a) (car b)) (valsi-parse-sort-key< (cdr a) (cdr b)))
        (t (< (car a) (car b)))))

(defconst valsi-parse-dep-re "(depends on \\([^)]*\\))"
  "Inline dependency recognizer (R5).")

(defun valsi-parse-deps (text)
  "Return a list of dependency-ref strings from TEXT (R5)."
  (when (string-match valsi-parse-dep-re text)
    (mapcar #'string-trim
            (split-string (match-string 1 text) "[ ,]+" t))))

(defconst valsi-parse-pathref-re "`\\([^`\n]*?/[^`\n]*?\\(?::[0-9]+\\)?\\)`"
  "Backticked path-ref recognizer (R6b).")

(defun valsi-parse-pathrefs (text)
  "Return a list of backticked path-refs from TEXT (R6b)."
  (let (refs (start 0))
    (while (string-match valsi-parse-pathref-re text start)
      (push (match-string 1 text) refs)
      (setq start (match-end 0)))
    (nreverse refs)))

(defconst valsi-parse-req-re
  "_Requirements:[ \t]*\\(.*?\\)_\\(?:[^[:alnum:]_]\\|$\\)"
  "Kiro requirements trace recognizer (R6a).
The closing underscore is the first one not followed by a word character,
so ids that contain underscores (FR_2, REQ_1_2) are kept whole.")

(defun valsi-parse-requirements (text)
  "Return a list of requirement ids if TEXT is an R6a trace line."
  (when (string-match valsi-parse-req-re text)
    (mapcar #'string-trim
            (split-string (match-string 1 text) "[ ,]+" t))))

(defconst valsi-parse-meta-re
  "^[ \t]*\\*\\*\\(Purpose\\|Goal\\|Independent Test\\|Checkpoint\\|Files\\|Spec\\|Verify\\):?\\*\\*:?"
  "Group/task meta-field recognizer (R4/R9/R10 labels).
Tolerates the colon inside (`**Verify:**') or outside (`**Verify**:') the bold.")

(defun valsi-parse-meta-label (text)
  "Return the meta label keyword in TEXT (downcased symbol) or nil."
  (when (string-match valsi-parse-meta-re text)
    (intern (downcase (replace-regexp-in-string
                       " " "-" (match-string 1 text))))))

(provide 'valsi-parse)
;;; valsi-parse.el ends here

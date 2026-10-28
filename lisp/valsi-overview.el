;;; valsi-overview.el --- Overview (README/ARCHITECTURE) grammar plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; AAP grammar plugin for overview documents: README.md, ARCHITECTURE.md, and
;; similar mostly-prose files.  These have the weakest inherent structure, so
;; this is the graceful-degradation showcase: capability follows structure --
;; every such file still gets an outline / table-of-contents, link following,
;; and a code-block inventory, and nothing more is claimed.
;;
;; Evidence tier: converging (README is ubiquitous; ARCHITECTURE codemaps are a
;; recurring but not standardized convention).

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-registry)
(require 'valsi-view)

(declare-function valsi-tree "valsi")

(defconst valsi-overview-link-re "\\[\\([^]]+\\)\\](\\([^)]+\\))"
  "Simple Markdown inline-link recognizer.
Parsing and following use `valsi-overview--links', which also handles
nested brackets (badge links) and parenthesized targets.")

(defconst valsi-overview-fence-re
  "^\\([ \t]*\\)\\(?:`\\{3,\\}\\|~\\{3,\\}\\)[ \t]*\\([A-Za-z0-9_+-]*\\)"
  "Fenced code-block delimiter recognizer (captures language).")

(defun valsi-overview--balanced-end (text pos open close)
  "Return the index after the CLOSE that balances the OPEN at POS in TEXT.
Backslash-escaped characters are skipped.  Return nil when unbalanced."
  (let ((depth 0) (i pos) (n (length text)) end)
    (while (and (not end) (< i n))
      (let ((c (aref text i)))
        (cond ((eq c ?\\) (setq i (1+ i)))
              ((eq c open) (setq depth (1+ depth)))
              ((eq c close)
               (setq depth (1- depth))
               (when (= depth 0) (setq end (1+ i))))))
      (setq i (1+ i)))
    end))

(defun valsi-overview--links (text)
  "Return (BEG END LABEL TARGET) for each inline link in TEXT, in order.
Brackets and parentheses nest, so a badge `[![alt](img)](url)' is one
link to url and a target such as `Foo_(bar)' keeps its parentheses."
  (let ((i 0) acc)
    (while (setq i (string-search "[" text i))
      (let* ((lend (valsi-overview--balanced-end text i ?\[ ?\]))
             (tend (and lend (< lend (length text))
                        (eq (aref text lend) ?\()
                        (valsi-overview--balanced-end text lend ?\( ?\)))))
        (if (and tend (> (- lend i) 2) (> (- tend lend) 2))
            (progn
              (push (list i tend
                          (substring text (1+ i) (1- lend))
                          (substring text (1+ lend) (1- tend)))
                    acc)
              (setq i tend))
          (setq i (1+ i)))))
    (nreverse acc)))

;;;; Parse

(defun valsi-overview-parse (content)
  "Parse CONTENT (a string) into an offset-based overview node tree."
  (valsi-parse-in-content content #'valsi-overview--parse-current))

(defun valsi-overview--parse-current ()
  "Parse the current buffer into an overview node tree (buffer positions)."
  (let ((root (valsi-node-create :type 'overview
                                :beg (point-min) :end (point-max)
                                :recognizer 'valsi-overview))
        (stack nil)                     ; (level . section-node)
        (fence nil))
    ;; Keep fenced lines: the overview records code blocks itself, using
    ;; the shared fence rules (backticks or tildes, closer at least as long).
    (dolist (line (valsi-parse-lines (current-buffer) t))
      (let* ((text (valsi-line-text line))
             (heading (unless (valsi-line-fenced line)
                        (valsi-parse-heading text))))
        (cond
         ;; inside a fence: only watch for its closer
         (fence
          (when (valsi-parse--fence-close-p text fence)
            (setq fence nil)))
         ;; code fence open
         ((setq fence (valsi-parse--fence-open text))
          (valsi-node-add-child
           (if stack (cdar stack) root)
           (valsi-node-create
            :type 'codeblock
            :beg (valsi-line-beg line) :end (valsi-line-end line)
            :recognizer 'valsi-overview-codeblock
            :props (list :lang (let ((l (and (string-match
                                              valsi-overview-fence-re text)
                                             (match-string 2 text))))
                                 (if (or (null l) (string-empty-p l))
                                     "text"
                                   l))))))
         ;; section headings -> outline
         (heading
          (let ((s (valsi-node-create
                    :type 'section
                    :beg (valsi-line-beg line) :end (valsi-line-end line)
                    :recognizer 'valsi-overview-section
                    :props (list :level (car heading) :title (cdr heading)))))
            (while (and stack (>= (caar stack) (car heading))) (pop stack))
            (if stack (valsi-node-add-child (cdar stack) s)
              (valsi-node-add-child root s))
            (push (cons (car heading) s) stack)
            (unless (valsi-node-prop root :title)
              (valsi-node-put root :title (cdr heading)))))
         ;; inline links anywhere
         (t
          (pcase-dolist (`(,beg ,end ,label ,target)
                         (valsi-overview--links text))
            (valsi-node-add-child
             (if stack (cdar stack) root)
             (valsi-node-create
              :type 'link
              :beg (+ (valsi-line-beg line) beg)
              :end (+ (valsi-line-beg line) end)
              :recognizer 'valsi-overview-link
              :props (list :label label :target target))))))))
    root))

;;;; Capabilities

(defun valsi-overview-capabilities (root)
  "Advertise supported actions for ROOT (structure-gated)."
  (let ((caps '(outline narrow)))
    (when (valsi-node-of-type root 'section)
      (setq caps (append caps '(next prev dashboard))))
    (when (valsi-node-of-type root 'link)
      (setq caps (append caps '(follow))))
    (delete-dups caps)))

;;;; Font-lock (deferred to markdown-mode; add a codeblock-lang hint)

(defvar valsi-overview-font-lock-keywords
  `((,valsi-overview-fence-re 2 'valsi-meta-face))
  "Font-lock keywords for overview buffers (light; markdown-mode does the rest).")

;;;; Commands

(defun valsi-overview--heading-positions ()
  "Return the line-start positions of section headings outside fences."
  (let (acc)
    (dolist (line (valsi-parse-lines (current-buffer)))
      (when (valsi-parse-heading (valsi-line-text line))
        (push (valsi-line-beg line) acc)))
    (nreverse acc)))

(defun valsi-overview-next-section ()
  "Move to the next section heading."
  (interactive)
  (let* ((eol (line-end-position))
         (next (cl-find-if (lambda (p) (> p eol))
                           (valsi-overview--heading-positions))))
    (if next
        (goto-char next)
      (end-of-line)
      (message "No further sections")
      (beginning-of-line))))

(defun valsi-overview-previous-section ()
  "Move to the previous section heading."
  (interactive)
  (beginning-of-line)
  (let* ((bol (point))
         (prev (cl-find-if (lambda (p) (< p bol))
                           (valsi-overview--heading-positions)
                           :from-end t)))
    (if prev
        (goto-char prev)
      (message "No previous sections"))))

(defun valsi-overview-follow ()
  "Follow the markdown link at point; open local files, message URLs."
  (interactive)
  (let* ((col (- (point) (line-beginning-position)))
         (link (cl-find-if
                (lambda (l) (and (<= (nth 0 l) col) (< col (nth 1 l))))
                (valsi-overview--links
                 (buffer-substring-no-properties
                  (line-beginning-position) (line-end-position))))))
    (if link
        (let ((target (nth 3 link)))
          (cond
           ((string-match-p "\\`https?:" target) (message "URL: %s" target))
           (t (let* ((parts (split-string target "#"))
                     (file (car parts)))
                (if (and (not (string-empty-p file)) (file-exists-p file))
                    (find-file-other-window file)
                  (message "Link target: %s" target))))))
      (message "No link at point"))))

(defun valsi-overview--dashboard-entries ()
  "Return a table-of-contents: one row per section."
  (mapcar
   (lambda (s)
     (list (valsi-node-beg s)
           (vector (make-string (* 2 (1- (valsi-node-prop s :level 1))) ?\s)
                   (valsi-node-prop s :title "")
                   (number-to-string (valsi-node-prop s :level 1)))))
   (valsi-node-of-type (valsi-tree) 'section)))

(defun valsi-overview-dashboard ()
  "Show the document's table of contents."
  (interactive)
  (valsi-view-tabulated
   "*Valsi outline*"
   [("" 8 nil) ("Section" 54 nil) ("Lvl" 4 t)]
   (valsi-overview--dashboard-entries)
   #'valsi-overview--dashboard-entries)
  (local-set-key (kbd "RET") #'valsi-overview--visit))

(defun valsi-overview--visit ()
  "Jump to the section on the current outline row (in the other window)."
  (interactive)
  (valsi-view-visit-source))

;;;; Registration

(defun valsi-overview-match (uri text)
  "Return a modest match score for a document URI + TEXT as an overview.
Deliberately low so more specific grammars win when they also match."
  (let ((name (or uri "")) (score 0))
    (when (string-match-p "\\(README\\|ARCHITECTURE\\|OVERVIEW\\|GUIDE\\|INTRO\\)\\(\\.[a-z-]+\\)?\\.md\\'"
                          name)
      (cl-incf score 3))
    (when (string-match-p "/doc\\(s\\)?/.*\\.md\\'" name) (cl-incf score 1))
    ;; any headed markdown gets a weak overview claim (the degradation floor)
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (when (re-search-forward "^#+[ \t]+" nil t) (cl-incf score 1)))
    score))

(defun valsi-overview-register ()
  "Register the overview grammar plugin."
  (valsi-registry-register
   (list :id 'overview
         :name "Overview (README/ARCHITECTURE)"
         :evidence 'converging
         :match #'valsi-overview-match
         :parse #'valsi-overview-parse
         :font-lock valsi-overview-font-lock-keywords
         :capabilities #'valsi-overview-capabilities
         :commands '((next . valsi-overview-next-section)
                     (prev . valsi-overview-previous-section)
                     (follow . valsi-overview-follow)
                     (dashboard . valsi-overview-dashboard)))))

(provide 'valsi-overview)
;;; valsi-overview.el ends here

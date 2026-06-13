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
  "Markdown inline-link recognizer.")

(defconst valsi-overview-fence-re "^\\([ \t]*\\)```[ \t]*\\([A-Za-z0-9_+-]*\\)"
  "Fenced code-block opener recognizer (captures language).")

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
        (in-fence nil))
    (dolist (line (valsi-parse-lines (current-buffer)))
      (let* ((text (valsi-line-text line))
             (heading (unless in-fence (valsi-parse-heading text))))
        (cond
         ;; code fence open/close
         ((string-match valsi-overview-fence-re text)
          (if in-fence
              (setq in-fence nil)
            (setq in-fence t)
            (valsi-node-add-child
             (if stack (cdar stack) root)
             (valsi-node-create
              :type 'codeblock
              :beg (valsi-line-beg line) :end (valsi-line-end line)
              :recognizer 'valsi-overview-codeblock
              :props (list :lang (let ((l (match-string 2 text)))
                                   (if (string-empty-p l) "text" l)))))))
         (in-fence nil)
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
         ((string-match valsi-overview-link-re text)
          (let ((start 0))
            (while (string-match valsi-overview-link-re text start)
              (valsi-node-add-child
               (if stack (cdar stack) root)
               (valsi-node-create
                :type 'link
                :beg (+ (valsi-line-beg line) (match-beginning 0))
                :end (+ (valsi-line-beg line) (match-end 0))
                :recognizer 'valsi-overview-link
                :props (list :label (match-string 1 text)
                             :target (match-string 2 text))))
              (setq start (match-end 0))))))))
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

(defconst valsi-overview--heading-re "^#+[ \t]+")

(defun valsi-overview-next-section ()
  "Move to the next section heading."
  (interactive)
  (end-of-line)
  (if (re-search-forward valsi-overview--heading-re nil t)
      (beginning-of-line)
    (message "No further sections") (beginning-of-line)))

(defun valsi-overview-previous-section ()
  "Move to the previous section heading."
  (interactive)
  (beginning-of-line)
  (unless (re-search-backward valsi-overview--heading-re nil t)
    (message "No previous sections")))

(defun valsi-overview-follow ()
  "Follow the markdown link at point; open local files, message URLs."
  (interactive)
  (save-excursion
    (beginning-of-line)
    (if (re-search-forward valsi-overview-link-re (line-end-position) t)
        (let ((target (match-string-no-properties 2)))
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
  (define-key valsi-view-list-mode-map (kbd "RET") #'valsi-overview--visit))

(defun valsi-overview--visit ()
  "Jump to the section on the current outline row (in the other window)."
  (interactive)
  (let ((pos (tabulated-list-get-id)))
    (when (and pos (integerp pos))
      (let ((buf (cl-find-if (lambda (b)
                               (with-current-buffer b
                                 (bound-and-true-p valsi-artifact-minor-mode)))
                             (buffer-list))))
        (when buf
          (pop-to-buffer buf)
          (goto-char (min pos (point-max)))
          (beginning-of-line))))))

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

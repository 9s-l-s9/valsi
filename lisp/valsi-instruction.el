;;; valsi-instruction.el --- Instruction-file grammar plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; AAP grammar plugin for instruction files: AGENTS.md, CLAUDE.md, GEMINI.md,
;; .cursor/rules/*.mdc, .github/instructions/*.  Biggest install base, weakest
;; inherent structure -- the best degradation test.  Recognizes heading-scopes,
;; instruction items, imperative emphasis markers, @imports and [[links]].
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
  "Imperative-emphasis marker recognizer.")

(defconst valsi-instruction-import-re "^[ \t]*@\\([^ \t\n]+\\)"
  "@import recognizer.")

(defconst valsi-instruction-link-re "\\[\\[\\([^]]+\\)\\]\\]"
  "Wiki [[link]] recognizer.")

;;;; Parse

(defun valsi-instruction-parse (content)
  "Parse CONTENT (a string) into an offset-based instruction node tree."
  (valsi-parse-in-content content #'valsi-instruction--parse-current))

(defun valsi-instruction--parse-current ()
  "Parse the current buffer into an instruction node tree (buffer positions)."
  (let ((root (valsi-node-create :type 'instruction
                                :beg (point-min) :end (point-max)
                                :recognizer 'valsi-instruction))
        (scope-stack nil))
    (dolist (line (valsi-parse-lines (current-buffer)))
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
            (valsi-node-add-child
             (if scope-stack (cdar scope-stack) root)
             (valsi-node-create
              :type 'item
              :beg (valsi-line-beg line) :end (valsi-line-end line)
              :recognizer 'valsi-instruction-item
              :confidence 'loose
              :props (list :text (cdr (valsi-parse-bullet text))
                           :emphasis (string-match-p
                                      valsi-instruction-emphasis-re text))))))))
    root))

;;;; Capabilities

(defun valsi-instruction-capabilities (root)
  "Advertise supported actions for ROOT."
  (let ((caps '(outline narrow info dashboard)))
    (when (valsi-node-of-type root 'scope)
      (push 'effective caps))
    (when (or (valsi-node-of-type root 'import))
      (push 'follow caps))
    (delete-dups caps)))

;;;; Font-lock

(defvar valsi-instruction-font-lock-keywords
  `((,valsi-instruction-emphasis-re . 'valsi-emphasis-face)
    (,valsi-instruction-import-re 1 'valsi-link-face)
    (,valsi-instruction-link-re 1 'valsi-link-face))
  "Font-lock keywords for instruction files.")

;;;; Commands

(defun valsi-instruction-effective-at-point ()
  "Echo the effective scope path (nearest-wins precedence) at point."
  (interactive)
  (let* ((root (valsi-tree))
         (path nil))
    (valsi-node-walk
     root
     (lambda (n _d)
       (when (and (eq (valsi-node-type n) 'scope)
                  (<= (valsi-node-beg n) (point)))
         ;; collect enclosing scopes by level ordering
         (push (cons (valsi-node-prop n :level) (valsi-node-prop n :title)) path))))
    (setq path (sort path (lambda (a b) (< (car a) (car b)))))
    (message "Effective scope: %s"
             (if path (mapconcat #'cdr path " > ") "(document root)"))))

(defun valsi-instruction-imports ()
  "List the @imports referenced by this file."
  (interactive)
  (let* ((root (valsi-tree))
         (imports (valsi-node-of-type root 'import)))
    (if (null imports)
        (message "No @imports")
      (message "Imports: %s"
               (mapconcat (lambda (n) (valsi-node-prop n :target)) imports ", ")))))

(defun valsi-instruction-follow ()
  "Follow the @import or [[link]] at point to its file."
  (interactive)
  (save-excursion
    (beginning-of-line)
    (cond
     ((re-search-forward valsi-instruction-import-re (line-end-position) t)
      (let ((f (match-string-no-properties 1)))
        (if (file-exists-p f) (find-file-other-window f)
          (message "No such import: %s" f))))
     ((re-search-forward valsi-instruction-link-re (line-end-position) t)
      (message "Link: %s" (match-string-no-properties 1)))
     (t (message "No import/link at point")))))

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
    (when (string-match-p "\\.cursor/rules/.*\\.mdc\\'\\|\\.github/instructions/"
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
                     (follow . valsi-instruction-follow)
                     (dashboard . valsi-instruction-dashboard)))))

(provide 'valsi-instruction)
;;; valsi-instruction.el ends here

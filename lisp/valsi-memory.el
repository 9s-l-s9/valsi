;;; valsi-memory.el --- Memory grammar plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; AAP grammar plugin for the agent-written memory family: a MEMORY.md index
;; of pointer lines plus per-fact record files carrying frontmatter
;; (name/description/metadata.type) and [[backlinks]].  Recognizes index
;; pointers, record frontmatter, and wiki links; navigates backlinks.
;;
;; Evidence tier: emergent.

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-registry)
(require 'valsi-view)

(declare-function valsi-tree "valsi")

(defconst valsi-memory-pointer-re
  "^[ \t]*-[ \t]+\\[\\([^]]+\\)\\](\\([^)]+\\))[ \t]*\\(?:[—-][ \t]*\\(.*\\)\\)?$"
  "Index pointer line recognizer: - [Title](file.md) — hook.")

(defconst valsi-memory-link-re "\\[\\[\\([^]]+\\)\\]\\]"
  "Wiki [[backlink]] recognizer.")

;;;; Parse

(defun valsi-memory-parse (content)
  "Parse CONTENT (a string) into an offset-based memory node tree."
  (valsi-parse-in-content content #'valsi-memory--parse-current))

(defun valsi-memory--parse-current ()
  "Parse the current buffer into a memory node tree (buffer positions)."
  (let ((root (valsi-node-create :type 'memory
                                :beg (point-min) :end (point-max)
                                :recognizer 'valsi-memory)))
    ;; frontmatter (record files)
    (save-excursion
      (goto-char (point-min))
      (when (looking-at "^---[ \t]*$")
        (let ((beg (point)))
          (forward-line 1)
          (when (re-search-forward "^---[ \t]*$" nil t)
            (valsi-node-add-child
             root (valsi-node-create
                   :type 'frontmatter :beg beg :end (line-end-position)
                   :recognizer 'valsi-memory-frontmatter))))))
    ;; index pointers + links
    (dolist (line (valsi-parse-lines (current-buffer)))
      (let ((text (valsi-line-text line)))
        (cond
         ((string-match valsi-memory-pointer-re text)
          (valsi-node-add-child
           root (valsi-node-create
                 :type 'pointer
                 :beg (valsi-line-beg line) :end (valsi-line-end line)
                 :recognizer 'valsi-memory-pointer
                 :props (list :title (match-string 1 text)
                              :target (match-string 2 text)
                              :hook (or (match-string 3 text) "")))))
         ((string-match valsi-memory-link-re text)
          (let ((start 0))
            (while (string-match valsi-memory-link-re text start)
              (valsi-node-add-child
               root (valsi-node-create
                     :type 'link
                     :beg (+ (valsi-line-beg line) (match-beginning 1))
                     :end (+ (valsi-line-beg line) (match-end 1))
                     :recognizer 'valsi-memory-link
                     :props (list :target (match-string 1 text))))
              (setq start (match-end 0))))))))
    root))

;;;; Capabilities

(defun valsi-memory-capabilities (root)
  "Advertise supported actions for ROOT."
  (let ((caps '(outline narrow)))
    (when (valsi-node-of-type root 'pointer)
      (setq caps (append caps '(dashboard follow))))
    (when (valsi-node-of-type root 'link)
      (setq caps (append caps '(follow backlinks))))
    (delete-dups caps)))

;;;; Font-lock

(defvar valsi-memory-font-lock-keywords
  `((,valsi-memory-link-re 1 'valsi-link-face)
    ("^\\([a-z_]+\\):" 1 'valsi-frontmatter-key-face))
  "Font-lock keywords for memory files.")

;;;; Commands

(defun valsi-memory-follow ()
  "Follow the [[link]] or index pointer at point to its file."
  (interactive)
  (save-excursion
    (beginning-of-line)
    (cond
     ((re-search-forward valsi-memory-pointer-re (line-end-position) t)
      (let ((f (match-string-no-properties 2)))
        (valsi-memory--visit f)))
     ((let ((eol (line-end-position)))
        (beginning-of-line)
        (re-search-forward valsi-memory-link-re eol t))
      (valsi-memory--visit (concat (match-string-no-properties 1) ".md")))
     (t (message "No link/pointer at point")))))

(defun valsi-memory--visit (name)
  "Open memory record NAME relative to the buffer's directory."
  (let* ((dir (if buffer-file-name (file-name-directory buffer-file-name)
                default-directory))
         (path (expand-file-name name dir)))
    (if (file-exists-p path)
        (find-file-other-window path)
      (message "No memory file: %s" name))))

(defun valsi-memory-backlinks ()
  "Find memory files linking to the current record via [[name]]."
  (interactive)
  (let* ((this (and buffer-file-name
                    (file-name-base buffer-file-name)))
         (dir (if buffer-file-name (file-name-directory buffer-file-name)
                default-directory)))
    (if (not this)
        (message "Buffer has no file")
      (let ((hits nil))
        (dolist (f (directory-files dir t "\\.md\\'"))
          (unless (string= f buffer-file-name)
            (with-temp-buffer
              (insert-file-contents f)
              (when (re-search-forward
                     (format "\\[\\[%s\\]\\]" (regexp-quote this)) nil t)
                (push (file-name-nondirectory f) hits)))))
        (if hits (message "Backlinks: %s" (mapconcat #'identity hits ", "))
          (message "No backlinks to %s" this))))))

(defun valsi-memory--dashboard-entries ()
  "Return one tabulated row per index pointer."
  (let* ((root (valsi-tree))
         (pointers (valsi-node-of-type root 'pointer)))
    (mapcar
     (lambda (p)
       (list (valsi-node-prop p :target)
             (vector (valsi-node-prop p :title "")
                     (valsi-node-prop p :target "")
                     (valsi-node-prop p :hook ""))))
     pointers)))

(defun valsi-memory-dashboard ()
  "Show the memory index as a navigable table."
  (interactive)
  (valsi-view-tabulated
   "*Valsi memory index*"
   [("Title" 30 t) ("File" 30 t) ("Hook" 50 nil)]
   (valsi-memory--dashboard-entries)
   #'valsi-memory--dashboard-entries)
  (define-key valsi-view-list-mode-map (kbd "RET") #'valsi-memory--dashboard-visit))

(defun valsi-memory--dashboard-visit ()
  "Open the memory file on the current index row."
  (interactive)
  (let ((file (tabulated-list-get-id)))
    (when file (find-file-other-window file))))

;;;; Registration

(defun valsi-memory-match (uri text)
  "Return a match score for a document URI + TEXT as a memory file."
  (let ((name (or uri ""))
        (score 0))
    (when (string-match-p "MEMORY\\.md\\'" name) (cl-incf score 4))
    (when (string-match-p "/memory/" name) (cl-incf score 3))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (when (re-search-forward valsi-memory-link-re nil t) (cl-incf score 1))
      (goto-char (point-min))
      (when (re-search-forward "^metadata:\\|^[ \t]+type:[ \t]*\\(user\\|feedback\\|project\\|reference\\)" nil t)
        (cl-incf score 2)))
    score))

(defun valsi-memory-register ()
  "Register the memory grammar plugin."
  (valsi-registry-register
   (list :id 'memory
         :name "Memory (index+record)"
         :evidence 'emergent
         :match #'valsi-memory-match
         :parse #'valsi-memory-parse
         :font-lock valsi-memory-font-lock-keywords
         :capabilities #'valsi-memory-capabilities
         :commands '((follow . valsi-memory-follow)
                     (backlinks . valsi-memory-backlinks)
                     (dashboard . valsi-memory-dashboard)))))

(provide 'valsi-memory)
;;; valsi-memory.el ends here

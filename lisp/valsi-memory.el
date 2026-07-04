;;; valsi-memory.el --- Memory grammar plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; AAP grammar plugin for the agent-written memory family (see
;; research/06-memory-grammar.md).  A memory store is two node genres that
;; reference each other:
;;
;;   index   -- MEMORY.md, a list of pointer lines: - [Title](file.md) -- hook
;;   record  -- one file per fact: YAML frontmatter (name/description/
;;              metadata.type in {user,feedback,project,reference}) then prose,
;;              with [[wiki-links]] to other records.
;;
;; It composes recognizers the earlier families already own: the strict
;; frontmatter header (prompt-file genre) and the [[wiki-link]] (instruction
;; genre).  Beyond navigation it adds two curation commands that are only
;; possible because the store is structured: `dedupe' (duplicate pointer targets
;; / near-identical record descriptions) and `stale-check' (index pointers whose
;; record file is missing, records whose [[link]] resolves to nothing).  Both
;; only report -- they never merge or delete (the descriptive invariant).
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
  "Index pointer line recognizer (R1): - [Title](file.md) — hook.")

(defconst valsi-memory-link-re "\\[\\[\\([^]]+\\)\\]\\]"
  "Wiki [[backlink]] recognizer (R5).")

(defconst valsi-memory-type-re
  "^[ \t]*type:[ \t]*\\(user\\|feedback\\|project\\|reference\\)\\_>"
  "Record-kind recognizer (R4): a `type:' line, flat or nested under metadata.")

(defconst valsi-memory-vocab
  '(:required ("name" "description")
    :known ("name" "description" "metadata" "type"))
  "Record frontmatter vocabulary: required + known top-level keys.")

;;;; Frontmatter scan (R2/R3)

(defun valsi-memory--frontmatter-bounds ()
  "Return (BEG . END) of the current buffer's leading YAML frontmatter, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "^---[ \t]*$")
      (let ((beg (point)))
        (forward-line 1)
        (when (re-search-forward "^---[ \t]*$" nil t)
          (cons beg (line-end-position)))))))

(defun valsi-memory--parse-frontmatter (beg end)
  "Parse top-level KEY: VALUE pairs between BEG and END in the current buffer."
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

(defun valsi-memory--record-kind (beg end)
  "Return the record kind symbol (R4) found between BEG and END, or nil."
  (save-excursion
    (goto-char beg)
    (when (re-search-forward valsi-memory-type-re end t)
      (intern (match-string 1)))))

;;;; Parse

(defun valsi-memory-parse (content)
  "Parse CONTENT (a string) into an offset-based memory node tree."
  (valsi-parse-in-content content #'valsi-memory--parse-current))

(defun valsi-memory--parse-current ()
  "Parse the current buffer into a memory node tree (buffer positions)."
  (let* ((bounds (valsi-memory--frontmatter-bounds))
         (kind (if bounds 'record 'index))
         (root (valsi-node-create :type 'memory
                                 :beg (point-min) :end (point-max)
                                 :recognizer 'valsi-memory
                                 :props (list :kind kind))))
    ;; record: typed frontmatter fields + record kind (R2/R3/R4)
    (when bounds
      (let* ((beg (car bounds)) (end (cdr bounds))
             (pairs (valsi-memory--parse-frontmatter beg end))
             (mtype (valsi-memory--record-kind beg end))
             (fm (valsi-node-create
                  :type 'frontmatter :beg beg :end end
                  :recognizer 'valsi-memory-frontmatter
                  :props (list :pairs pairs :mtype mtype))))
        (valsi-node-put root :mtype mtype)
        (dolist (p pairs)
          (valsi-node-add-child
           fm (valsi-node-create
               :type 'field :beg beg :end end
               :recognizer 'valsi-memory-field
               :props (list :key (car p) :value (cdr p)
                            :known (and (member (car p)
                                                (plist-get valsi-memory-vocab
                                                           :known))
                                        t)
                            :required (and (member (car p)
                                                   (plist-get valsi-memory-vocab
                                                              :required))
                                           t)))))
        (valsi-node-add-child root fm)))
    ;; index pointers (R1) + wiki links (R5)
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

;;;; Accessors (pure over the tree)

(defun valsi-memory--root (&optional root)
  "Return ROOT or the client's current tree."
  (or root (valsi-tree)))

(defun valsi-memory-kind (&optional root)
  "Return `index' or `record' for ROOT."
  (valsi-node-prop (valsi-memory--root root) :kind 'index))

(defun valsi-memory-record-type (&optional root)
  "Return the record-kind symbol (user/feedback/project/reference) for ROOT."
  (valsi-node-prop (valsi-memory--root root) :mtype))

(defun valsi-memory-pointers (&optional root)
  "Return the index pointer nodes in ROOT."
  (valsi-node-of-type (valsi-memory--root root) 'pointer))

(defun valsi-memory-links (&optional root)
  "Return the [[wiki-link]] target strings in ROOT."
  (mapcar (lambda (n) (valsi-node-prop n :target))
          (valsi-node-of-type (valsi-memory--root root) 'link)))

;;;; Capabilities

(defun valsi-memory-capabilities (root)
  "Advertise supported actions for ROOT."
  (let ((caps '(outline narrow)))
    (when (valsi-node-of-type root 'pointer)
      (setq caps (append caps '(dashboard follow dedupe stale-check))))
    (when (valsi-node-of-type root 'link)
      (setq caps (append caps '(follow backlinks stale-check))))
    (delete-dups caps)))

;;;; Font-lock

(defvar valsi-memory-font-lock-keywords
  `((,valsi-memory-link-re 1 'valsi-link-face)
    ("^\\([a-z_]+\\):" 1 'valsi-frontmatter-key-face))
  "Font-lock keywords for memory files.")

;;;; Navigation commands

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

;;;; Dedupe (rung 4) -- report only, never merge

(defun valsi-memory--dup-targets (root)
  "Return index-pointer targets in ROOT that appear more than once."
  (let ((counts (make-hash-table :test 'equal)) dups)
    (dolist (p (valsi-memory-pointers root))
      (let ((tgt (valsi-node-prop p :target)))
        (puthash tgt (1+ (gethash tgt counts 0)) counts)))
    (maphash (lambda (tgt n) (when (> n 1) (push tgt dups))) counts)
    (nreverse dups)))

(defun valsi-memory--norm-desc (s)
  "Normalize description S for near-duplicate comparison."
  (string-trim (downcase (replace-regexp-in-string "[ \t]+" " " (or s "")))))

(defun valsi-memory--dup-descriptions (file-descs)
  "Return groups of files sharing a normalized description.
FILE-DESCS is an alist of (FILE . DESCRIPTION); returns a list of file lists,
one per description shared by two or more files."
  (let ((by-desc (make-hash-table :test 'equal)) groups)
    (dolist (fd file-descs)
      (let ((k (valsi-memory--norm-desc (cdr fd))))
        (unless (string= "" k)
          (puthash k (cons (car fd) (gethash k by-desc)) by-desc))))
    (maphash (lambda (_k files)
               (when (> (length files) 1) (push (nreverse files) groups)))
             by-desc)
    (nreverse groups)))

(defun valsi-memory--sibling-descriptions ()
  "Return an alist of (FILE . DESCRIPTION) for record files beside this buffer."
  (let* ((dir (if buffer-file-name (file-name-directory buffer-file-name)
                default-directory))
         acc)
    (dolist (f (directory-files dir t "\\.md\\'"))
      (unless (string-match-p "MEMORY\\.md\\'" f)
        (with-temp-buffer
          (insert-file-contents f)
          (let ((b (valsi-memory--frontmatter-bounds)))
            (when b
              (let ((desc (cdr (assoc "description"
                                      (valsi-memory--parse-frontmatter
                                       (car b) (cdr b))))))
                (when desc
                  (push (cons (file-name-nondirectory f) desc) acc))))))))
    (nreverse acc)))

(defun valsi-memory-dedupe ()
  "Report duplicate index pointers and near-identical record descriptions.
Reports only -- the human decides what to merge (descriptive invariant)."
  (interactive)
  (let ((dup-targets (valsi-memory--dup-targets (valsi-tree)))
        (dup-descs (valsi-memory--dup-descriptions
                    (valsi-memory--sibling-descriptions))))
    (if (and (null dup-targets) (null dup-descs))
        (message "valsi-memory: no duplicates found")
      (with-current-buffer (get-buffer-create "*valsi-memory-dedupe*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Memory duplicate candidates:\n\n")
          (when dup-targets
            (insert "Index pointers to the same target:\n")
            (dolist (tgt dup-targets) (insert "  - " tgt "\n"))
            (insert "\n"))
          (when dup-descs
            (insert "Records with near-identical descriptions:\n")
            (dolist (g dup-descs)
              (insert "  - " (mapconcat #'identity g ", ") "\n")))
          (goto-char (point-min))
          (special-mode))
        (display-buffer (current-buffer)))
      (message "valsi-memory: %d duplicate group(s)"
               (+ (length dup-targets) (length dup-descs))))))

;;;; Stale-check (rung 4) -- facts vs the store

(defun valsi-memory--dangling-links (links existing)
  "Return the subset of LINKS (target strings) not present in EXISTING.
EXISTING is a list of record base names (without .md)."
  (cl-remove-if (lambda (l) (member l existing)) (delete-dups (copy-sequence links))))

(defun valsi-memory--record-basenames (dir)
  "Return the base names (sans .md) of record files in DIR."
  (mapcar #'file-name-base
          (cl-remove-if (lambda (f) (string-match-p "MEMORY\\.md\\'" f))
                        (directory-files dir t "\\.md\\'"))))

(defun valsi-memory-stale-check ()
  "Flag store drift: missing pointer targets and dangling [[links]].
Reports index pointers whose record file is gone and record [[links]] that
resolve to no sibling record.  Informational -- dangling links may just mark a
record not yet written."
  (interactive)
  (let* ((root (valsi-tree))
         (dir (if buffer-file-name (file-name-directory buffer-file-name)
                default-directory))
         (missing
          (cl-remove-if
           (lambda (tgt) (file-exists-p (expand-file-name tgt dir)))
           (mapcar (lambda (p) (valsi-node-prop p :target))
                   (valsi-memory-pointers root))))
         (dangling
          (valsi-memory--dangling-links
           (valsi-memory-links root)
           (valsi-memory--record-basenames dir))))
    (if (and (null missing) (null dangling))
        (message "valsi-memory: store is consistent")
      (with-current-buffer (get-buffer-create "*valsi-memory-stale*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Memory store drift:\n\n")
          (when missing
            (insert "Index pointers whose file is missing:\n")
            (dolist (m missing) (insert "  - " m "\n"))
            (insert "\n"))
          (when dangling
            (insert "Dangling [[links]] (target record not found):\n")
            (dolist (d dangling) (insert "  - [[" d "]]\n")))
          (goto-char (point-min))
          (special-mode))
        (display-buffer (current-buffer)))
      (message "valsi-memory: %d missing, %d dangling"
               (length missing) (length dangling)))))

;;;; Dashboard

(defun valsi-memory--dashboard-entries ()
  "Return one tabulated row per index pointer."
  (let ((pointers (valsi-memory-pointers (valsi-tree))))
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
      (when (re-search-forward
             (concat "^metadata:\\|" valsi-memory-type-re) nil t)
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
                     (dedupe . valsi-memory-dedupe)
                     (stale-check . valsi-memory-stale-check)
                     (dashboard . valsi-memory-dashboard)))))

(provide 'valsi-memory)
;;; valsi-memory.el ends here

;;; valsi-changelog.el --- Changelog grammar plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; AAP grammar plugin for CHANGELOG.md following Keep a Changelog.
;;
;; Evidence tier: standardized (keepachangelog.com + SemVer).  Recognizes the
;; `## [version] - date' release headings (and `## [Unreleased]'), the six
;; fixed category headings, and entry bullets.  Provides release navigation, a
;; releases dashboard, and a lint (descending SemVer order, ISO dates, empty or
;; unknown categories).

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-registry)
(require 'valsi-view)

(declare-function valsi-tree "valsi")

(defconst valsi-changelog-categories
  '("Added" "Changed" "Deprecated" "Removed" "Fixed" "Security")
  "The six Keep a Changelog category headings.")

(defconst valsi-changelog-release-re
  "^##[ \t]+\\[?\\(Unreleased\\|v?[0-9]+\\(?:\\.[0-9]+\\)*[^]]*\\)\\]?\\(?:[ \t]*[-–][ \t]*\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\|[^\n]*\\)\\)?"
  "Release heading recognizer: ## [version] - date.")

(defconst valsi-changelog-category-re
  "^###[ \t]+\\(Added\\|Changed\\|Deprecated\\|Removed\\|Fixed\\|Security\\)[ \t]*$"
  "Category heading recognizer.")

;;;; Parse

(defun valsi-changelog-parse (content)
  "Parse CONTENT (a string) into an offset-based changelog node tree."
  (valsi-parse-in-content content #'valsi-changelog--parse-current))

(defun valsi-changelog--parse-current ()
  "Parse the current buffer into a changelog node tree (buffer positions)."
  (let ((root (valsi-node-create :type 'changelog
                                :beg (point-min) :end (point-max)
                                :recognizer 'valsi-changelog))
        (release nil) (category nil))
    (dolist (line (valsi-parse-lines (current-buffer)))
      (let ((text (valsi-line-text line)))
        (cond
         ((string-match valsi-changelog-release-re text)
          (let ((ver (match-string 1 text))
                (date (match-string 2 text)))
            (setq release (valsi-node-create
                           :type 'release
                           :beg (valsi-line-beg line) :end (valsi-line-end line)
                           :recognizer 'valsi-changelog-release
                           :props (list :version ver :date date
                                        :unreleased (and ver (string-match-p
                                                             "Unreleased" ver)))))
            (setq category nil)
            (valsi-node-add-child root release)))
         ((string-match valsi-changelog-category-re text)
          (setq category (valsi-node-create
                          :type 'category
                          :beg (valsi-line-beg line) :end (valsi-line-end line)
                          :recognizer 'valsi-changelog-category
                          :props (list :name (match-string 1 text))))
          (valsi-node-add-child (or release root) category))
         ((valsi-parse-bullet text)
          (valsi-node-add-child
           (or category release root)
           (valsi-node-create :type 'entry
                             :beg (valsi-line-beg line) :end (valsi-line-end line)
                             :recognizer 'valsi-changelog-entry
                             :props (list :text (cdr (valsi-parse-bullet text)))))))))
    root))

;;;; Capabilities

(defun valsi-changelog-capabilities (root)
  "Advertise supported actions for ROOT."
  (let ((caps '(outline narrow)))
    (when (valsi-node-of-type root 'release)
      (setq caps (append caps '(next prev info dashboard lint))))
    caps))

;;;; Font-lock

(defvar valsi-changelog-font-lock-keywords
  `((,valsi-changelog-release-re (1 'valsi-id-face) (2 'valsi-meta-face nil t))
    ("^##[ \t]+\\[?Unreleased\\]?" . 'valsi-in-progress-face)
    (,valsi-changelog-category-re 1 'valsi-story-face))
  "Font-lock keywords for changelog buffers.")

;;;; Commands

(defun valsi-changelog-next-release ()
  "Move to the next release heading."
  (interactive)
  (end-of-line)
  (if (re-search-forward valsi-changelog-release-re nil t)
      (beginning-of-line)
    (message "No further releases") (beginning-of-line)))

(defun valsi-changelog-previous-release ()
  "Move to the previous release heading."
  (interactive)
  (beginning-of-line)
  (unless (re-search-backward valsi-changelog-release-re nil t)
    (message "No previous releases")))

(defun valsi-changelog-info ()
  "Echo a summary of the release at point."
  (interactive)
  (let ((rel (valsi-node-at-line (valsi-tree) (point) 'release)))
    (if (not rel)
        (message "No release at point")
      (message "%s%s — %d categories, %d entries"
               (valsi-node-prop rel :version)
               (if (valsi-node-prop rel :date)
                   (format " (%s)" (valsi-node-prop rel :date)) "")
               (length (valsi-node-of-type rel 'category))
               (length (valsi-node-of-type rel 'entry))))))

(defun valsi-changelog--dashboard-entries ()
  "Return one tabulated row per release."
  (mapcar
   (lambda (rel)
     (list (valsi-node-beg rel)
           (vector (or (valsi-node-prop rel :version) "?")
                   (or (valsi-node-prop rel :date)
                       (if (valsi-node-prop rel :unreleased) "unreleased" "-"))
                   (number-to-string (length (valsi-node-of-type rel 'entry))))))
   (valsi-node-of-type (valsi-tree) 'release)))

(defun valsi-changelog-dashboard ()
  "Show the releases in this changelog as a table."
  (interactive)
  (valsi-view-tabulated
   "*Valsi changelog*"
   [("Version" 24 t) ("Date" 16 t) ("Entries" 8 t)]
   (valsi-changelog--dashboard-entries)
   #'valsi-changelog--dashboard-entries))

(defun valsi-changelog-lint ()
  "Lint the changelog: SemVer order, ISO dates, empty/unknown categories."
  (interactive)
  (let* ((root (valsi-tree))
         (releases (valsi-node-of-type root 'release))
         (issues nil)
         (prev-key nil))
    (dolist (rel releases)
      (let* ((ver (valsi-node-prop rel :version))
             (date (valsi-node-prop rel :date))
             (unreleased (valsi-node-prop rel :unreleased))
             (key (valsi-parse-sort-key ver)))
        (unless unreleased
          (when (and date (not (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" date)))
            (push (format "%s: non-ISO date %S" ver date) issues))
          (when (and prev-key key (valsi-parse-sort-key< prev-key key))
            (push (format "%s out of order (should be newest-first)" ver) issues))
          (when key (setq prev-key key)))
        (dolist (cat (valsi-node-of-type rel 'category))
          (let ((name (valsi-node-prop cat :name)))
            (unless (member name valsi-changelog-categories)
              (push (format "%s: unknown category %S" ver name) issues))
            (unless (valsi-node-of-type cat 'entry)
              (push (format "%s: empty category %s" ver name) issues))))))
    (if (null issues)
        (message "Valsi changelog: clean (%d releases)" (length releases))
      (with-current-buffer (get-buffer-create "*valsi-changelog-lint*")
        (erase-buffer)
        (insert (format "Changelog lint: %d issue(s)\n\n" (length issues)))
        (dolist (i (nreverse issues)) (insert "  - " i "\n"))
        (special-mode)
        (display-buffer (current-buffer)))
      (message "Valsi changelog: %d issue(s)" (length issues)))))

;;;; Registration

(defun valsi-changelog-match (uri text)
  "Return a match score for a document URI + TEXT as a changelog."
  (let ((name (or uri "")) (score 0))
    (when (string-match-p "CHANGELOG\\(\\.md\\)?\\'\\|HISTORY\\.md\\'\\|NEWS\\.md\\'"
                          name)
      (cl-incf score 4))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (when (re-search-forward "^##[ \t]+\\[Unreleased\\]" nil t) (cl-incf score 3))
      (goto-char (point-min))
      (when (re-search-forward valsi-changelog-category-re nil t) (cl-incf score 2))
      (goto-char (point-min))
      (when (re-search-forward "[Kk]eep a [Cc]hangelog" nil t) (cl-incf score 2)))
    score))

(defun valsi-changelog-register ()
  "Register the changelog grammar plugin."
  (valsi-registry-register
   (list :id 'changelog
         :name "Changelog (Keep a Changelog)"
         :evidence 'standardized
         :match #'valsi-changelog-match
         :parse #'valsi-changelog-parse
         :font-lock valsi-changelog-font-lock-keywords
         :capabilities #'valsi-changelog-capabilities
         :commands '((next . valsi-changelog-next-release)
                     (prev . valsi-changelog-previous-release)
                     (info . valsi-changelog-info)
                     (dashboard . valsi-changelog-dashboard)
                     (lint . valsi-changelog-lint)))))

(provide 'valsi-changelog)
;;; valsi-changelog.el ends here

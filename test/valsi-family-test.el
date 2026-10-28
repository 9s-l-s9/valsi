;;; valsi-family-test.el --- ERT tests for changelog/decision/overview grammars -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unit tests for the changelog, decision (ADR), and overview grammar
;; plugins: parse structure, match scoring, and capabilities.  Pure over
;; content strings.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-changelog)
(require 'valsi-decision)
(require 'valsi-overview)

(defconst valsi-family-test--changelog
  (concat "# Changelog\n\n"
          "All notable changes.  Based on Keep a Changelog.\n\n"
          "## [Unreleased]\n\n"
          "### Added\n\n- New thing\n\n"
          "## [1.1.0] - 2026-01-15\n\n"
          "### Fixed\n\n- A bug\n- Another bug\n\n"
          "## [1.0.0] - 2025-12-01\n\n"
          "### Added\n\n- Initial release\n")
  "A well-formed Keep a Changelog fixture.")

;;;; Changelog

(ert-deftest valsi-test-changelog-parse-releases ()
  "Releases, categories, and entries are extracted with their props."
  (let* ((root (valsi-changelog-parse valsi-family-test--changelog))
         (releases (valsi-node-of-type root 'release)))
    (should (= 3 (length releases)))
    (should (valsi-node-prop (car releases) :unreleased))
    (let ((rel (nth 1 releases)))
      (should (equal "1.1.0" (valsi-node-prop rel :version)))
      (should (equal "2026-01-15" (valsi-node-prop rel :date)))
      (should (= 1 (length (valsi-node-of-type rel 'category))))
      (should (= 2 (length (valsi-node-of-type rel 'entry)))))))

(ert-deftest valsi-test-changelog-release-heading-forms ()
  "Bare, parenthesized, and linked release headings keep the date (issue #2)."
  (dolist (heading '("## [1.2.0] - 2024-01-01"
                     "## 1.2.0 - 2024-01-01"
                     "## v1.2.0 (2024-01-01)"
                     "## [1.2.0](https://x/y) - 2024-01-01"))
    (let ((rel (car (valsi-node-of-type
                     (valsi-changelog-parse (concat heading "\n"))
                     'release))))
      (should (equal "1.2.0" (valsi-node-prop rel :version)))
      (should (equal "2024-01-01" (valsi-node-prop rel :date)))))
  (should (equal "1.0.0-rc.1"
                 (valsi-node-prop
                  (car (valsi-node-of-type
                        (valsi-changelog-parse "## 1.0.0-rc.1\n") 'release))
                  :version)))
  (should-not (valsi-node-of-type
               (valsi-changelog-parse "## 2 reasons to upgrade\n") 'release)))

(ert-deftest valsi-test-changelog-match-scoring ()
  "A real changelog scores high on URI + text; unrelated text scores 0."
  (should (>= (valsi-changelog-match "/p/CHANGELOG.md"
                                    valsi-family-test--changelog)
              9))
  (should (> (valsi-changelog-match nil valsi-family-test--changelog) 0))
  (should (= 0 (valsi-changelog-match "/p/notes.md"
                                     "Just some prose.\nNothing here.\n"))))

(ert-deftest valsi-test-changelog-capabilities-gated ()
  "Release-bearing changelogs gain nav/lint; empty ones only outline."
  (let ((full (valsi-changelog-capabilities
               (valsi-changelog-parse valsi-family-test--changelog)))
        (bare (valsi-changelog-capabilities
               (valsi-changelog-parse "# Changelog\n\nNothing yet.\n"))))
    (should (memq 'lint full))
    (should (memq 'next full))
    (should (equal '(outline narrow) bare))))

(ert-deftest valsi-test-changelog-lint-seeded-violations ()
  "Lint reports out-of-order releases and empty categories."
  (let ((root (valsi-changelog-parse
               (concat "# Changelog\n\n"
                       "## [1.0.0] - 2025-12-01\n\n### Added\n\n- x\n\n"
                       "## [1.1.0] - 15/01/2026\n\n### Fixed\n")))
        result)
    (unwind-protect
        (cl-letf (((symbol-function 'valsi-tree) (lambda () root))
                  ((symbol-function 'switch-to-buffer)
                   (lambda (buffer &rest _) (setq result buffer))))
          (valsi-changelog-lint)
          (with-current-buffer result
            (goto-char (point-min))
            (should (search-forward "non-ISO date" nil t))
            (should (search-forward "out of order" nil t))
            (should (search-forward "empty category Fixed" nil t))))
      (when (buffer-live-p result) (kill-buffer result)))))

;;;; Decision (ADR)

(defconst valsi-family-test--adr
  (concat "# 3. Use JSON-RPC for AAP\n\n"
          "## Status\n\nAccepted\n\n"
          "## Context\n\nWe need a wire protocol.\n\n"
          "## Decision\n\nUse JSON-RPC.\n\n"
          "## Consequences\n\nLSP-style framing.\n")
  "A canonical Nygard-style ADR fixture.")

(ert-deftest valsi-test-decision-parse-structure ()
  "Title, status, and sections are extracted from an ADR."
  (let ((root (valsi-decision-parse valsi-family-test--adr)))
    (should (equal "3. Use JSON-RPC for AAP" (valsi-node-prop root :title)))
    (should (equal "Accepted" (valsi-node-prop root :status)))
    (should (equal '("Status" "Context" "Decision" "Consequences")
                   (mapcar (lambda (s) (valsi-node-prop s :title))
                           (valsi-node-of-type root 'section))))))

(ert-deftest valsi-test-decision-superseded-status ()
  "A superseded status keeps its by-reference."
  (let ((root (valsi-decision-parse
               "# 1. Old\n\n## Status\n\nSuperseded by ADR-0004\n")))
    (should (equal "Superseded by ADR-0004" (valsi-node-prop root :status)))))

(ert-deftest valsi-test-decision-match-scoring ()
  "ADR path + Status/Context/Decision headings score; prose does not."
  (should (>= (valsi-decision-match "/p/doc/adr/0003-use-jsonrpc.md"
                                   valsi-family-test--adr)
              9))
  (should (= 0 (valsi-decision-match "/p/notes.md" "No structure at all.\n"))))

(ert-deftest valsi-test-decision-capabilities-set-status ()
  "set-status is advertised only when a status value exists."
  (should (memq 'set-status
                (valsi-decision-capabilities
                 (valsi-decision-parse valsi-family-test--adr))))
  (should-not (memq 'set-status
                    (valsi-decision-capabilities
                     (valsi-decision-parse "# 1. Bare\n\nProse only.\n")))))

(ert-deftest valsi-test-decision-lint-missing-sections ()
  "Lint flags a missing status and missing canonical sections."
  (let ((root (valsi-decision-parse "# 2. Half-done\n\n## Context\n\nWhy.\n"))
        (reported nil))
    (cl-letf (((symbol-function 'valsi-tree) (lambda () root))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq reported (apply #'format fmt args)))))
      (valsi-decision-lint))
    (should (string-match-p "missing Status value" reported))
    (should (string-match-p "missing section: Decision" reported))
    (should (string-match-p "missing section: Consequences" reported))
    (should-not (string-match-p "missing section: Context" reported))))

;; Regression tests for issue #1.

(defun valsi-family-test--set-status (text status)
  "Return TEXT after `valsi-decision-set-status' chooses STATUS."
  (with-temp-buffer
    (insert text)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) status)))
      (valsi-decision-set-status))
    (buffer-string)))

(ert-deftest valsi-test-decision-set-status-empty-section ()
  "An empty Status section gains a value; the next heading survives."
  (should (equal "# T\n\n## Status\n\nAccepted\n\n## Context\nfoo\n"
                 (valsi-family-test--set-status
                  "# T\n\n## Status\n\n## Context\nfoo\n" "Accepted")))
  (should (equal "# T\n\n## Status\n\nAccepted\n"
                 (valsi-family-test--set-status
                  "# T\n\n## Status\n\n" "Accepted")))
  (should (equal "# T\n\n## Status\n\nAccepted\n"
                 (valsi-family-test--set-status
                  "# T\n\n## Status" "Accepted"))))

(ert-deftest valsi-test-decision-set-status-replaces-value ()
  "An existing status value line is replaced in place."
  (should (equal "# T\n\n## Status\n\nRejected\n\n## Context\n"
                 (valsi-family-test--set-status
                  "# T\n\n## Status\n\nProposed\n\n## Context\n"
                  "Rejected"))))

;; Regression tests for issue #65.

(defun valsi-family-test--lint (text)
  "Return the message `valsi-decision-lint' reports for TEXT."
  (let ((root (valsi-decision-parse text)) (reported nil))
    (cl-letf (((symbol-function 'valsi-tree) (lambda () root))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq reported (apply #'format fmt args)))))
      (valsi-decision-lint))
    reported))

(ert-deftest valsi-test-decision-status-variants ()
  "Clauses, lowercase words, and bullets are standard; prefixes are not."
  (dolist (case '(("Superseded by ADR-0005" . "Superseded by ADR-0005")
                  ("accepted" . "Accepted")
                  ("- Accepted" . "Accepted")
                  ("* **proposed**" . "Proposed")
                  ("Acceptedish thing" . "Acceptedish thing")))
    (let* ((text (format (concat "# 1. X\n\n## Status\n\n%s\n\n"
                                 "## Context\nc\n## Decision\nd\n"
                                 "## Consequences\ne\n")
                         (car case)))
           (reported (valsi-family-test--lint text)))
      (should (equal (cdr case)
                     (valsi-node-prop (valsi-decision-parse text) :status)))
      (if (equal (car case) "Acceptedish thing")
          (should (string-match-p "non-standard status" reported))
        (should (equal "Valsi ADR: complete" reported))))))

;; Regression tests for issue #66.

(defconst valsi-family-test--madr
  (concat "---\nstatus: accepted\ndate: 2026-01-01\n---\n"
          "# Use MADR\n\n"
          "## Context and Problem Statement\nc\n"
          "## Decision Outcome\nd\n")
  "A MADR 3 record: frontmatter status, MADR section names.")

(ert-deftest valsi-test-decision-madr-record ()
  "MADR frontmatter status and section names satisfy the lint."
  (let ((root (valsi-decision-parse valsi-family-test--madr)))
    (should (equal "Accepted" (valsi-node-prop root :status)))
    (should (equal "Use MADR" (valsi-node-prop root :title))))
  (should (equal "Valsi ADR: complete"
                 (valsi-family-test--lint valsi-family-test--madr)))
  (should (string-prefix-p "---\nstatus: rejected\ndate: 2026-01-01\n---\n"
                           (valsi-family-test--set-status
                            valsi-family-test--madr "Rejected"))))

(ert-deftest valsi-test-decision-inline-status ()
  "An inline Status line before the first section is the status."
  (let ((text (concat "# 1. X\n\nStatus: Superseded by ADR-0002\n\n"
                      "## Context\nc\n## Decision\nd\n"
                      "## Consequences\nStatus: not this\n")))
    (should (equal "Superseded by ADR-0002"
                   (valsi-node-prop (valsi-decision-parse text) :status)))
    (should (equal "Valsi ADR: complete" (valsi-family-test--lint text)))
    (should (string-prefix-p "# 1. X\n\nStatus: Deprecated\n\n"
                             (valsi-family-test--set-status text "Deprecated"))))
  (should (equal "Proposed"
                 (valsi-node-prop
                  (valsi-decision-parse "# X\n\n* **Status:** proposed\n")
                  :status))))

;; Regression tests for issue #67.

(defun valsi-family-test--dashboard-files (project visited)
  "Return the dashboard file names for VISITED inside PROJECT."
  (with-temp-buffer
    (setq buffer-file-name visited
          default-directory (file-name-directory visited))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) 'p))
              ((symbol-function 'project-root) (lambda (_) project)))
      (mapcar (lambda (e) (file-relative-name (car e) project))
              (valsi-decision--dashboard-entries)))))

(ert-deftest valsi-test-decision-dashboard-directory ()
  "The visited ADR directory wins; decisions/ counts; README is skipped."
  (let* ((d (file-name-as-directory (make-temp-file "valsi-dec" t)))
         (adr (expand-file-name "doc/adr" d))
         (dec (expand-file-name "docs/decisions" d)))
    (unwind-protect
        (progn
          (make-directory adr t)
          (make-directory dec t)
          (with-temp-file (expand-file-name "0001-a.md" adr)
            (insert "# 1. A\n\n## Status\n\nAccepted\n"))
          (with-temp-file (expand-file-name "README.md" adr)
            (insert "# ADR index\n"))
          (with-temp-file (expand-file-name "use-x.md" dec)
            (insert "# B\n\n## Status\n\nProposed\n"))
          (should (equal '("docs/decisions/use-x.md")
                         (valsi-family-test--dashboard-files
                          d (expand-file-name "use-x.md" dec))))
          (should (equal '("doc/adr/0001-a.md")
                         (valsi-family-test--dashboard-files
                          d (expand-file-name "notes.md" d))))
          (delete-directory (expand-file-name "doc" d) t)
          (should (equal '("docs/decisions/use-x.md")
                         (valsi-family-test--dashboard-files
                          d (expand-file-name "notes.md" d)))))
      (delete-directory d t))))

;;;; Overview

(defconst valsi-family-test--readme
  (concat "# My Project\n\n"
          "See the [manual](doc/manual.md) and [site](https://example.org).\n\n"
          "## Install\n\n"
          "```sh\nmake install\n```\n\n"
          "### Notes\n\nDetails.\n\n"
          "## Usage\n\nRun it.\n")
  "A README fixture with sections, links, and a code block.")

(ert-deftest valsi-test-overview-parse-structure ()
  "Sections nest by level; links and code blocks carry props."
  (let* ((root (valsi-overview-parse valsi-family-test--readme))
         (sections (valsi-node-of-type root 'section))
         (links (valsi-node-of-type root 'link))
         (blocks (valsi-node-of-type root 'codeblock)))
    (should (equal "My Project" (valsi-node-prop root :title)))
    (should (= 4 (length sections)))
    ;; "Notes" (level 3) nests under "Install" (level 2).
    (let ((install (cl-find "Install" sections
                            :key (lambda (s) (valsi-node-prop s :title))
                            :test #'string=)))
      (should (valsi-node-of-type install 'section)))
    (should (= 2 (length links)))
    (should (equal "doc/manual.md" (valsi-node-prop (car links) :target)))
    (should (equal '("sh")
                   (mapcar (lambda (b) (valsi-node-prop b :lang)) blocks)))))

(ert-deftest valsi-test-overview-match-scoring ()
  "README names score modestly; headed markdown gets the weak floor."
  (should (>= (valsi-overview-match "/p/README.md" valsi-family-test--readme) 4))
  (should (= 1 (valsi-overview-match "/p/misc.md" "# Heading\n\ntext\n")))
  (should (= 0 (valsi-overview-match "/p/misc.txt" "no headings here\n"))))

(ert-deftest valsi-test-overview-capabilities-structure-gated ()
  "Capabilities follow structure: follow needs links, nav needs sections."
  (let ((full (valsi-overview-capabilities
               (valsi-overview-parse valsi-family-test--readme)))
        (bare (valsi-overview-capabilities
               (valsi-overview-parse "just prose\n"))))
    (should (memq 'follow full))
    (should (memq 'dashboard full))
    (should (equal '(outline narrow) bare))))

(provide 'valsi-family-test)
;;; valsi-family-test.el ends here

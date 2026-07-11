;;; valsi-instruction-test.el --- ERT tests for the instruction grammar -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unit tests for the instruction-file grammar (Sprint 8): frontmatter-glob
;; scope, [[links]], lint, one-source->many sync, and scaffold.  Pure over
;; content strings -- no filesystem except the sync/lint on-disk checks, which
;; use temp files.

;;; Code:

(require 'ert)
(require 'valsi-instruction)

(defun valsi-instruction-test--tree (content)
  "Parse CONTENT and return the instruction node tree."
  (valsi-instruction-parse content))

;;;; R4 -- frontmatter glob scope

(ert-deftest valsi-test-instruction-frontmatter-cursor ()
  "A Cursor .mdc frontmatter yields globs + description."
  (let* ((content "---\ndescription: API rules\nglobs:\n  - \"src/api/**/*.ts\"\n  - \"src/routes/**/*.ts\"\nalwaysApply: false\n---\n\n# Rules\n\n- Validate input.\n")
         (root (valsi-instruction-test--tree content))
         (fm (car (valsi-node-of-type root 'frontmatter))))
    (should fm)
    (should (equal "API rules" (valsi-node-prop fm :description)))
    (should (equal '("src/api/**/*.ts" "src/routes/**/*.ts")
                   (valsi-node-prop fm :globs)))
    (should (eq nil (valsi-node-prop fm :always-apply)))))

(ert-deftest valsi-test-instruction-frontmatter-applyto ()
  "A Copilot .instructions.md frontmatter yields an applyTo glob."
  (let* ((content "---\napplyTo: \"**/*.py\"\n---\n\n# Python\n\n- Use type hints.\n")
         (root (valsi-instruction-test--tree content))
         (fm (car (valsi-node-of-type root 'frontmatter))))
    (should fm)
    (should (equal '("**/*.py") (valsi-node-prop fm :apply-to)))))

(ert-deftest valsi-test-instruction-frontmatter-always ()
  "alwaysApply: true is recognized as a global (glob-less) rule."
  (let* ((content "---\nalwaysApply: true\n---\n\n# Global\n\n- Always tidy.\n")
         (root (valsi-instruction-test--tree content))
         (fm (car (valsi-node-of-type root 'frontmatter))))
    (should (eq t (valsi-node-prop fm :always-apply)))))

(ert-deftest valsi-test-instruction-no-frontmatter ()
  "A plain AGENTS.md has no frontmatter node."
  (let* ((content "# AGENTS.md\n\n- Do the thing.\n")
         (root (valsi-instruction-test--tree content)))
    (should (null (valsi-node-of-type root 'frontmatter)))))

;;;; R6 -- links, R2 -- emphasis

(ert-deftest valsi-test-instruction-links-and-emphasis ()
  "Item nodes carry [[links]] and an emphasis flag."
  (let* ((content "# Rules\n\n- IMPORTANT: see [[api-reference]] and [[style]].\n- plain item\n")
         (root (valsi-instruction-test--tree content))
         (items (valsi-node-of-type root 'item)))
    (should (= 2 (length items)))
    (should (valsi-node-prop (car items) :emphasis))
    (should (equal '("api-reference" "style")
                   (valsi-node-prop (car items) :links)))
    (should-not (valsi-node-prop (cadr items) :emphasis))
    (should (null (valsi-node-prop (cadr items) :links)))))

;;;; R3 -- heading scopes nest

(ert-deftest valsi-test-instruction-scope-nesting ()
  "Nested headings produce a nested scope tree; items attach to nearest."
  (let* ((content "# Top\n\n- a\n\n## Sub\n\n- b\n- c\n")
         (root (valsi-instruction-test--tree content))
         (top (car (valsi-node-of-type root 'scope))))
    (should (equal "Top" (valsi-node-prop top :title)))
    ;; the Sub scope is a child of Top
    (should (valsi-node-of-type top 'scope))
    (should (= 3 (length (valsi-node-of-type root 'item))))))

(ert-deftest valsi-test-instruction-effective-scope-excludes-prior-siblings ()
  "The active scope path contains ancestors, not earlier sibling headings."
  (let* ((content "# Alpha\n- alpha rule\n# Beta\n## Nested\n- beta rule\n")
         (root (valsi-instruction-test--tree content))
         (pos (string-match "beta rule" content))
         (path (valsi-instruction--scope-path-at root pos)))
    (should (equal '("Beta" "Nested")
                   (mapcar (lambda (scope) (valsi-node-prop scope :title))
                           path)))))

;;;; Lint

(ert-deftest valsi-test-instruction-lint-unscoped-frontmatter ()
  "Frontmatter with no globs/applyTo/alwaysApply is flagged."
  (let* ((content "---\ndescription: orphan rule\n---\n\n# X\n\n- y\n")
         (root (valsi-instruction-test--tree content))
         (findings (valsi-instruction--lint-collect root nil)))
    (should (= 1 (length findings)))
    (should (string-match-p "no globs/applyTo"
                            (cdr (car findings))))))

(ert-deftest valsi-test-instruction-lint-scoped-clean ()
  "Frontmatter with a glob is not flagged as unscoped."
  (let* ((content "---\nglobs:\n  - \"*.ts\"\n---\n\n# X\n\n- y\n")
         (root (valsi-instruction-test--tree content)))
    (should (null (valsi-instruction--lint-collect root nil)))))

(ert-deftest valsi-test-instruction-lint-dangling-import ()
  "A @import that does not resolve on disk is flagged when DIR is given."
  (let* ((dir (make-temp-file "valsi-instr" t))
         (content "# X\n\n@does-not-exist.md\n\n- y\n")
         (root (valsi-instruction-test--tree content))
         (findings (valsi-instruction--lint-collect root dir)))
    (unwind-protect
        (progn
          (should (= 1 (length findings)))
          (should (string-match-p "dangling @import" (cdr (car findings)))))
      (delete-directory dir t))))

(ert-deftest valsi-test-instruction-lint-live-import-clean ()
  "A @import that resolves on disk is not flagged."
  (let* ((dir (make-temp-file "valsi-instr" t))
         (peer (expand-file-name "peer.md" dir)))
    (unwind-protect
        (progn
          (with-temp-buffer (insert "# peer\n") (write-region nil nil peer))
          (let* ((content "# X\n\n@peer.md\n\n- y\n")
                 (root (valsi-instruction-test--tree content)))
            (should (null (valsi-instruction--lint-collect root dir)))))
      (delete-directory dir t))))

;;;; Sync (one source -> many peer targets)

(ert-deftest valsi-test-instruction-sync-append ()
  "Sync appends a managed region to a target that has none."
  (let* ((source "# AGENTS\n\n- shared rule\n")
         (target "# CLAUDE.md\n\nlocal notes\n")
         (out (valsi-instruction--sync-region source target)))
    ;; target's own content survives
    (should (string-match-p "local notes" out))
    ;; the managed region carries the source
    (should (string-match-p "shared rule" out))
    (should (string-match-p (regexp-quote valsi-instruction-sync-begin) out))
    (should (string-match-p (regexp-quote valsi-instruction-sync-end) out))))

(ert-deftest valsi-test-instruction-sync-idempotent ()
  "Re-syncing identical source is a fixed point (byte-identical)."
  (let* ((source "# AGENTS\n\n- shared rule\n")
         (target "# CLAUDE.md\n\nlocal notes\n")
         (once (valsi-instruction--sync-region source target))
         (twice (valsi-instruction--sync-region source once)))
    (should (string= once twice))))

(ert-deftest valsi-test-instruction-sync-replaces-region ()
  "Sync replaces an existing managed region, preserving outside content."
  (let* ((v1 (valsi-instruction--sync-region "# S\n\n- one\n"
                                            "# T\n\nkeep me\n"))
         (v2 (valsi-instruction--sync-region "# S\n\n- two\n" v1)))
    (should (string-match-p "keep me" v2))
    (should (string-match-p "- two" v2))
    (should-not (string-match-p "- one" v2))
    ;; still exactly one managed region
    (should (= 1 (valsi-instruction-test--count valsi-instruction-sync-begin v2)))))

(defun valsi-instruction-test--count (needle haystack)
  "Return the number of non-overlapping NEEDLE occurrences in HAYSTACK."
  (let ((n 0) (start 0))
    (while (string-match (regexp-quote needle) haystack start)
      (cl-incf n)
      (setq start (match-end 0)))
    n))

;;;; Scaffold

(ert-deftest valsi-test-instruction-scaffold-template ()
  "The scaffold template is a valid, parseable instruction file."
  (let* ((body (valsi-instruction--scaffold-template "AGENTS"))
         (root (valsi-instruction-test--tree body)))
    (should (string-match-p "^# AGENTS" body))
    (should (string-match-p "ALWAYS" body))
    (should (>= (length (valsi-node-of-type root 'scope)) 3))))

(provide 'valsi-instruction-test)
;;; valsi-instruction-test.el ends here

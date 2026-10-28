;;; valsi-instruction-fixes-test.el --- Instruction grammar regressions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Regression tests for instruction-grammar bugs: case-sensitive emphasis
;; (#59), inline @imports (#60), scaffold paths and titles (#61), and
;; frontmatter value forms (#62).

;;; Code:

(require 'ert)
(require 'valsi-instruction)

;;;; #59 -- emphasis markers are uppercase only

(ert-deftest valsi-test-instruction-emphasis-case-sensitive ()
  "Lowercase prose is not emphasis; uppercase markers are, regardless of fold."
  (let ((case-fold-search t))
    (let ((root (valsi-instruction-parse
                 "# T\n- always run tests\n- you must not do x\n- never mind\n- NEVER push\n")))
      (should (equal '(nil nil nil t)
                     (mapcar (lambda (i) (valsi-node-prop i :emphasis))
                             (valsi-node-of-type root 'item)))))
    (should (= 0 (valsi-instruction-match "/x/notes.md" "we should always do this")))
    (should (= 1 (valsi-instruction-match "/x/notes.md" "ALWAYS do this")))))

;;;; #60 -- @imports anywhere on a line, path-like targets only

(ert-deftest valsi-test-instruction-import-inline-and-mentions ()
  "Inline imports are recognized; @mentions and inline code are not imports."
  (let* ((content (concat "@someone please review\n@@x\n  @./a.md\n"
                          "- See @docs/missing.md for details\n"
                          "Read @~/.claude/x.md, then `@not/this.md`.\n"
                          "mail me at a@b.com\n"))
         (root (valsi-instruction-parse content))
         (imports (valsi-node-of-type root 'import)))
    (should (equal '("./a.md" "docs/missing.md" "~/.claude/x.md")
                   (mapcar (lambda (n) (valsi-node-prop n :target)) imports)))
    ;; A line-start import spans its line; an inline one spans `@target'.
    (should (equal "  @./a.md\n"
                   (substring content (valsi-node-beg (nth 0 imports))
                              (valsi-node-end (nth 0 imports)))))
    (should (equal "@docs/missing.md"
                   (substring content (valsi-node-beg (nth 1 imports))
                              (valsi-node-end (nth 1 imports)))))
    ;; The bulleted line stays an item, carrying its import.
    (should (= 1 (length (valsi-node-of-type root 'item))))))

(ert-deftest valsi-test-instruction-import-inline-lint-and-graph ()
  "Lint and the import graph see inline imports, not @mentions."
  (let* ((dir (make-temp-file "valsi-instr" t))
         (file (expand-file-name "AGENTS.md" dir))
         (content "@someone hi\n- Branching rules @docs/branching.md\n"))
    (unwind-protect
        (progn
          (with-temp-file file (insert content))
          (should (equal '("docs/branching.md")
                         (valsi-instruction--imports-of-file file)))
          (should (equal '("dangling @import: docs/branching.md")
                         (mapcar #'cdr (valsi-instruction--lint-collect
                                        (valsi-instruction-parse content)
                                        dir)))))
      (delete-directory dir t))))

(ert-deftest valsi-test-instruction-import-font-lock-matcher ()
  "The font-lock matcher finds each path-like import target in turn."
  (with-temp-buffer
    (insert "@user hi\nsee @a.md and @b/c\n")
    (goto-char (point-min))
    (let (found)
      (while (valsi-instruction--import-matcher (point-max))
        (push (match-string-no-properties 1) found))
      (should (equal '("a.md" "b/c") (nreverse found))))))

;;;; #61 -- scaffold creates parent directories and strips suffixes

(ert-deftest valsi-test-instruction-scaffold-missing-parent-and-title ()
  "Scaffolding into a missing directory works and titles drop suffixes."
  (let ((dir (make-temp-file "valsi-instr" t))
        (buffers nil))
    (unwind-protect
        (dolist (case '((".cursor/rules/api.mdc" . "# api\n")
                        (".github/instructions/x.instructions.md" . "# x\n")
                        ("AGENTS.md" . "# AGENTS\n")))
          (let ((file (expand-file-name (car case) dir)))
            (save-window-excursion
              (valsi-instruction-scaffold file)
              (push (current-buffer) buffers)
              (should (equal file buffer-file-name))
              (should (string-prefix-p (cdr case) (buffer-string))))))
      (dolist (b buffers)
        (with-current-buffer b (set-buffer-modified-p nil))
        (kill-buffer b))
      (delete-directory dir t))))

(provide 'valsi-instruction-fixes-test)
;;; valsi-instruction-fixes-test.el ends here

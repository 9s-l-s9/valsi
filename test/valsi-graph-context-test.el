;;; valsi-graph-context-test.el --- Shared graph source context tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Verify single reads, grammar ownership, parsed edges, and visible failures.

;;; Code:

(require 'ert)
(require 'valsi-graph)

(defmacro valsi-graph-context--with-project (&rest body)
  "Run BODY with ROOT and isolated graph registrations."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "valsi-graph-context-" t)))
          (default-directory root)
          (valsi-graph-edge-sources (copy-sequence valsi-graph-edge-sources))
          (valsi-graph--source-grammars (copy-tree valsi-graph--source-grammars))
          (valsi-graph--errors nil))
     (unwind-protect
         (cl-letf (((symbol-function 'valsi-graph--project-root) (lambda () root)))
           (unless (valsi-registry-all) (valsi-registry-register-bundled))
           ,@body)
       (delete-directory root t))))

(defun valsi-graph-context--write (root name text)
  "Write TEXT to NAME under ROOT, creating its parent directory."
  (let ((file (expand-file-name name root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))
    file))

(ert-deftest valsi-graph-context-one-read-and-parse-shared-by-eligible-sources ()
  "All built-ins and additional sources share one read and parse per file."
  (valsi-graph-context--with-project
    (valsi-graph-context--write root "PLAN.md" "## Phase 1\n- [ ] T1 `src/a.el`\n## Phase 2\n")
    (valsi-graph-context--write root "MEMORY.md" "See [[note]].\n")
    (valsi-graph-context--write root "AGENTS.md" "@rules.md\n")
    (valsi-graph-context--write root "README.md" "# Guide\nInstall `src/example.sh`.\n")
    (let ((read-file (symbol-function 'insert-file-contents))
          (parse (symbol-function 'valsi-registry-parse-content))
          (reads (make-hash-table :test #'equal))
          (parses (make-hash-table :test #'equal)) calls)
      (valsi-graph-register-edge-source
       (lambda (file)
         (should buffer-read-only)
         (should (equal file buffer-file-name))
         (should (string-match-p "Phase 1" (buffer-string)))
         (should (eq 'plan (valsi-node-type valsi-graph-current-tree)))
         (push file calls)
         (list (list (valsi-graph--source-name file) "custom" "ok")))
       '(plan))
      (cl-letf (((symbol-function 'insert-file-contents)
                 (lambda (file &rest args)
                   (when (string-prefix-p root file)
                     (puthash file (1+ (gethash file reads 0)) reads))
                   (apply read-file file args)))
                ((symbol-function 'valsi-registry-parse-content)
                 (lambda (grammar text)
                   (puthash valsi-graph--current-file
                            (1+ (gethash valsi-graph--current-file parses 0)) parses)
                   (funcall parse grammar text))))
        (should (= 5 (length (valsi-graph--collect)))))
      (should (= 4 (hash-table-count reads)))
      (should (seq-every-p (lambda (count) (= 1 count)) (hash-table-values reads)))
      (should (= 3 (hash-table-count parses)))
      (should (seq-every-p (lambda (count) (= 1 count)) (hash-table-values parses)))
      (should (equal (list (expand-file-name "PLAN.md" root)) calls)))))

(ert-deftest valsi-graph-context-grammar-and-fences-exclude-unrelated-edges ()
  "Only grammar-owned nodes contribute; examples and unrelated prose do not."
  (valsi-graph-context--with-project
    (valsi-graph-context--write
     root "README.md" "# Guide\nUse `a/b` and [[manual]].\n## Part 1\n## Part 2\n")
    (valsi-graph-context--write
     root "PLAN.md"
     (concat "## Phase 1\n- [ ] T1 `src/real.el` `https://example.org/a`\n"
             "_Requirements: FR_1_\n```md\n## Phase fake\n"
             "- [ ] T9 `src/fake.el`\n_Requirements: FAKE_\n```\n## Phase 2\n"
             "Prose mentions `docs/unrelated.md`.\n"))
    (valsi-graph-context--write
     root "MEMORY.md" "[[real]]\n- [Pointer](pointer.md) — hook\n~~~\n[[fake]]\n~~~\n")
    (valsi-graph-context--write
     root "AGENTS.md" "See @real.md\n```\n@fake.md\n```\n")
    (let ((edges (mapcar #'cdr (valsi-graph--collect))))
      (should (= 6 (length edges)))
      (should (member '("PLAN.md" "path" "src/real.el") edges))
      (should (member '("PLAN.md" "trace" "FR_1") edges))
      (should (member '("PLAN.md" "phase" "Phase 1 → Phase 2") edges))
      (should (member '("MEMORY.md" "link" "real") edges))
      (should (member '("MEMORY.md" "index" "pointer.md") edges))
      (should (member '("AGENTS.md" "import" "real.md") edges)))))

(ert-deftest valsi-graph-context-registration-updates-grammar-filter ()
  "Re-registration replaces ownership while keeping the one-argument API."
  (valsi-graph-context--with-project
    (valsi-graph-context--write root "PLAN.md" "- [ ] T1 Work\n")
    (valsi-graph-context--write root "MEMORY.md" "[[note]]\n")
    (let ((valsi-graph-edge-sources nil)
          (fn (lambda (file) (list (list (valsi-graph--source-name file) "test"
                                        (symbol-name valsi-graph-current-grammar))))))
      (valsi-graph-register-edge-source fn '(plan))
      (should (equal "PLAN.md" (cadar (valsi-graph--collect))))
      (valsi-graph-register-edge-source fn '(memory))
      (should (= 1 (length valsi-graph-edge-sources)))
      (should (equal "MEMORY.md" (cadar (valsi-graph--collect))))
      (valsi-graph-register-edge-source fn)
      (should (= 2 (length (valsi-graph--collect)))))))

(ert-deftest valsi-graph-context-failures-are-visible-alongside-successes ()
  "Directory, file, and source failures produce rows without hiding good edges."
  (valsi-graph-context--with-project
    (valsi-graph-context--write root "MEMORY.md" "[[good]]\n")
    (valsi-graph-context--write root "unreadable.md" "[[hidden]]\n")
    (make-directory (expand-file-name "blocked" root))
    (valsi-graph-register-edge-source (lambda (_) (error "source exploded")) '(memory))
    (let ((read-file (symbol-function 'insert-file-contents))
          (read-directory (symbol-function 'directory-files)))
      (cl-letf (((symbol-function 'insert-file-contents)
                 (lambda (file &rest args)
                   (when (equal "unreadable.md" (file-name-nondirectory file))
                     (signal 'file-error '("unreadable fixture")))
                   (apply read-file file args)))
                ((symbol-function 'directory-files)
                 (lambda (directory &rest args)
                   (when (string-suffix-p "/blocked" (directory-file-name directory))
                     (signal 'file-error '("blocked fixture")))
                   (apply read-directory directory args))))
        (let* ((rows (valsi-graph--entries))
               (errors (seq-filter (lambda (row) (equal "error" (aref (cadr row) 1))) rows)))
          (should (= 4 (length rows)))
          (should (= 3 (length errors)))
          (should (equal "good" (aref (cadar rows) 2)))
          (dolist (text '("source exploded" "unreadable fixture" "blocked fixture"))
            (should (seq-some (lambda (row) (string-match-p text (aref (cadr row) 2))) errors))))))))

(provide 'valsi-graph-context-test)
;;; valsi-graph-context-test.el ends here

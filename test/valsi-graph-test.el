;;; valsi-graph-test.el --- ERT tests for the cross-artifact graph -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unit tests for the cross-artifact graph: the built-in
;; edge sources (instruction @imports, memory [[wiki]]/index, plan trace/path,
;; phase-successor), the pluggable registration API, and the file-tagged
;; collect/entries used by the navigable view.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-graph)

(defmacro valsi-graph-test--with-file (content var &rest body)
  "Write CONTENT to a temp .md file bound to VAR, run BODY, then delete it."
  (declare (indent 2))
  `(let ((,var (make-temp-file "valsi-graph-test" nil ".md" ,content)))
     (unwind-protect (progn ,@body)
       (delete-file ,var))))

;;;; Built-in edge sources

(ert-deftest valsi-test-graph-instruction ()
  "@import lines become import edges."
  (valsi-graph-test--with-file "# rules\n@./shared.md\n@base.md\n" f
    (let ((edges (valsi-graph--edges-instruction f)))
      (should (member (list (file-name-nondirectory f) "import" "./shared.md")
                      edges))
      (should (= 2 (length edges))))))

(ert-deftest valsi-test-graph-memory ()
  "[[wiki]] links and index pointers become edges."
  (valsi-graph-test--with-file
      "- [Foo](foo.md) — h\nSee [[bar]].\n" f
    (let ((edges (valsi-graph--edges-memory f)))
      (should (member (list (file-name-nondirectory f) "link" "bar") edges))
      (should (member (list (file-name-nondirectory f) "index" "foo.md")
                      edges)))))

(ert-deftest valsi-test-graph-plan ()
  "Path-refs and requirement traces become edges."
  (valsi-graph-test--with-file
      "Do work in `lisp/valsi.el`.\n_Requirements: 1.2, 3.1_\n" f
    (let ((edges (valsi-graph--edges-plan f)))
      (should (member (list (file-name-nondirectory f) "path" "lisp/valsi.el")
                      edges))
      (should (member (list (file-name-nondirectory f) "trace" "1.2, 3.1")
                      edges)))))

(ert-deftest valsi-test-graph-phase ()
  "Consecutive phase headings yield successor edges."
  (valsi-graph-test--with-file
      "## Sprint 1: alpha\ntext\n## Sprint 2: beta\nmore\n## Sprint 3: gamma\n" f
    (let ((edges (valsi-graph--edges-phase f))
          (base (file-name-nondirectory f)))
      (should (= 2 (length edges)))
      (should (member (list base "phase" "Sprint 1: alpha → Sprint 2: beta")
                      edges))
      (should (member (list base "phase" "Sprint 2: beta → Sprint 3: gamma")
                      edges)))))

(ert-deftest valsi-test-graph-phase-single ()
  "A lone phase heading yields no successor edge."
  (valsi-graph-test--with-file "## Sprint 1: only\n" f
    (should (null (valsi-graph--edges-phase f)))))

;;;; Pluggable registration

(ert-deftest valsi-test-graph-register ()
  "Registering an edge source adds it once (idempotent)."
  (let ((valsi-graph-edge-sources (copy-sequence valsi-graph-edge-sources))
        (fn (lambda (_f) nil)))
    (valsi-graph-register-edge-source fn)
    (should (memq fn valsi-graph-edge-sources))
    (let ((n (length valsi-graph-edge-sources)))
      (valsi-graph-register-edge-source fn)
      (should (= n (length valsi-graph-edge-sources))))))

;;;; Collect / entries (file-tagged, for navigation)

(ert-deftest valsi-test-graph-collect-tags-file ()
  "Collect tags each edge with its source file; entries use it as the row id."
  (valsi-graph-test--with-file "See [[bar]].\n" f
    (cl-letf (((symbol-function 'valsi-graph--artifact-files)
               (lambda () (list f)))
              (valsi-graph-edge-sources (list #'valsi-graph--edges-memory)))
      (let ((collected (valsi-graph--collect))
            (entries (valsi-graph--entries)))
        (should (equal f (car (car collected))))
        ;; entry = (ID VECTOR); ID is the absolute file (RET target)
        (should (equal f (car (car entries))))
        (should (equal "bar" (aref (cadr (car entries)) 2)))))))

(provide 'valsi-graph-test)
;;; valsi-graph-test.el ends here

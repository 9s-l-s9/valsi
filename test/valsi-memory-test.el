;;; valsi-memory-test.el --- ERT tests for the memory grammar -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unit tests for the memory grammar (Sprint 10): index vs record
;; discrimination, record-kind frontmatter (user/feedback/project/reference,
;; nested or flat), typed fields, index pointers + [[wiki-links]], and the pure
;; cores of dedupe (duplicate targets / near-identical descriptions) and
;; stale-check (dangling links).  Pure over content strings.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-memory)

(defun valsi-memory-test--tree (content)
  "Parse CONTENT as a memory file, returning the node tree."
  (valsi-memory-parse content))

;;;; Index vs record (kind)

(ert-deftest valsi-test-memory-kind-index ()
  "A pointer-only file is an index."
  (let ((root (valsi-memory-test--tree
               "# Memory index\n\n- [Foo](foo.md) — a hook\n")))
    (should (eq 'index (valsi-memory-kind root)))))

(ert-deftest valsi-test-memory-kind-record ()
  "A frontmatter file is a record."
  (let ((root (valsi-memory-test--tree
               "---\nname: foo\ndescription: a fact\n---\n\nBody.\n")))
    (should (eq 'record (valsi-memory-kind root)))))

;;;; Record kind (R4) -- nested and flat

(ert-deftest valsi-test-memory-type-nested ()
  "metadata.type nested under metadata: is read as the record kind."
  (let ((root (valsi-memory-test--tree
               "---\nname: x\ndescription: y\nmetadata:\n  type: feedback\n---\n\nz\n")))
    (should (eq 'feedback (valsi-memory-record-type root)))))

(ert-deftest valsi-test-memory-type-flat ()
  "A flat type: line is also read as the record kind."
  (let ((root (valsi-memory-test--tree
               "---\nname: x\ndescription: y\ntype: project\n---\n\nz\n")))
    (should (eq 'project (valsi-memory-record-type root)))))

;;;; Typed fields (R2/R3)

(ert-deftest valsi-test-memory-fields-typed ()
  "Frontmatter fields carry :known / :required flags from the vocabulary."
  (let* ((root (valsi-memory-test--tree
                "---\nname: x\ndescription: y\nbogus: 1\n---\n\nz\n"))
         (fields (valsi-node-of-type root 'field)))
    (should (= 3 (length fields)))
    (let ((name (cl-find "name" fields
                         :key (lambda (f) (valsi-node-prop f :key))
                         :test #'string=))
          (bogus (cl-find "bogus" fields
                          :key (lambda (f) (valsi-node-prop f :key))
                          :test #'string=)))
      (should (valsi-node-prop name :required))
      (should (valsi-node-prop name :known))
      (should-not (valsi-node-prop bogus :known)))))

;;;; Index pointers (R1)

(ert-deftest valsi-test-memory-pointer ()
  "An index pointer captures title/target/hook."
  (let* ((root (valsi-memory-test--tree "- [Foo Bar](foo.md) — the hook\n"))
         (p (car (valsi-memory-pointers root))))
    (should p)
    (should (equal "Foo Bar" (valsi-node-prop p :title)))
    (should (equal "foo.md" (valsi-node-prop p :target)))
    (should (equal "the hook" (valsi-node-prop p :hook)))))

(ert-deftest valsi-test-memory-pointer-no-hook ()
  "A bare pointer without a hook still parses."
  (let* ((root (valsi-memory-test--tree "- [Foo](foo.md)\n"))
         (p (car (valsi-memory-pointers root))))
    (should p)
    (should (equal "foo.md" (valsi-node-prop p :target)))))

;;;; Wiki links (R5)

(ert-deftest valsi-test-memory-links ()
  "Body [[links]] are collected as link targets."
  (let ((root (valsi-memory-test--tree
               "---\nname: x\ndescription: y\n---\n\nSee [[alpha]] and [[beta]].\n")))
    (should (equal '("alpha" "beta") (valsi-memory-links root)))))

;;;; Capabilities

(ert-deftest valsi-test-memory-capabilities-index ()
  "An index advertises dedupe + stale-check + dashboard."
  (let* ((root (valsi-memory-test--tree "- [Foo](foo.md) — h\n"))
         (caps (valsi-memory-capabilities root)))
    (should (memq 'dedupe caps))
    (should (memq 'stale-check caps))
    (should (memq 'dashboard caps))))

(ert-deftest valsi-test-memory-capabilities-record ()
  "A record with links advertises follow + backlinks."
  (let* ((root (valsi-memory-test--tree
                "---\nname: x\ndescription: y\n---\n\n[[other]]\n"))
         (caps (valsi-memory-capabilities root)))
    (should (memq 'backlinks caps))
    (should (memq 'follow caps))))

;;;; Dedupe pure core

(ert-deftest valsi-test-memory-dup-targets ()
  "Two pointers to the same target are reported once."
  (let ((root (valsi-memory-test--tree
               "- [A](same.md) — a\n- [B](same.md) — b\n- [C](other.md) — c\n")))
    (should (equal '("same.md") (valsi-memory--dup-targets root)))))

(ert-deftest valsi-test-memory-dup-descriptions ()
  "Records with a normalized-identical description are grouped."
  (let ((groups (valsi-memory--dup-descriptions
                 '(("a.md" . "Ground research first")
                   ("b.md" . "ground  research   first")
                   ("c.md" . "something else")))))
    (should (= 1 (length groups)))
    (should (equal '("a.md" "b.md") (car groups)))))

(ert-deftest valsi-test-memory-norm-desc ()
  "Description normalization collapses case + whitespace."
  (should (equal "ground research first"
                 (valsi-memory--norm-desc "  Ground   research First "))))

;;;; Stale-check pure core

(ert-deftest valsi-test-memory-dangling-links ()
  "Links with no matching record base name are dangling."
  (should (equal '("gamma")
                 (valsi-memory--dangling-links
                  '("alpha" "beta" "gamma" "alpha")
                  '("alpha" "beta")))))

(provide 'valsi-memory-test)
;;; valsi-memory-test.el ends here

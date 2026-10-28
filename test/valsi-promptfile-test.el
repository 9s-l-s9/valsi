;;; valsi-promptfile-test.el --- ERT tests for the prompt-file grammar -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unit tests for the prompt-file grammar: per-type vocabularies
;; (skill/subagent/command), the eager/lazy disclosure split, frontmatter
;; validation + unknown-key warnings, description-as-trigger + test-fire, and
;; the argument-placeholder recognizer.  Pure over content strings; the parse
;; URI is bound so type discrimination is deterministic without a live buffer.

;;; Code:

(require 'ert)
(require 'valsi-promptfile)

(defun valsi-promptfile-test--tree (content &optional uri)
  "Parse CONTENT as prompt file at URI, returning the node tree."
  (let ((valsi-promptfile--parse-uri uri))
    (valsi-promptfile-parse content)))

;;;; Type discrimination (R3)

(ert-deftest valsi-test-promptfile-type-skill ()
  "A SKILL.md URI resolves to the skill vocabulary."
  (let* ((content "---\nname: x\ndescription: does a thing when asked\n---\n\n# X\n")
         (root (valsi-promptfile-test--tree content "skills/x/SKILL.md")))
    (should (eq 'skill (valsi-promptfile-type root)))))

(ert-deftest valsi-test-promptfile-type-subagent ()
  "An agents/ URI resolves to the subagent vocabulary."
  (let* ((content "---\nname: rev\ndescription: reviews code after edits\ntools: Read, Grep\n---\n\nYou are a reviewer.\n")
         (root (valsi-promptfile-test--tree content ".claude/agents/rev.md")))
    (should (eq 'subagent (valsi-promptfile-type root)))))

(ert-deftest valsi-test-promptfile-type-command ()
  "A commands/ URI resolves to the command vocabulary."
  (let* ((content "---\ndescription: make a commit\nargument-hint: [msg]\n---\n\nCommit: $ARGUMENTS\n")
         (root (valsi-promptfile-test--tree content ".claude/commands/commit.md")))
    (should (eq 'command (valsi-promptfile-type root)))))

;;;; Frontmatter + typed fields (R1/R2)

(ert-deftest valsi-test-promptfile-fields-typed ()
  "Fields carry :known and :required flags from the type vocabulary."
  (let* ((content "---\nname: x\ndescription: a real description that triggers\nbogus: 1\n---\n\n# X\n")
         (root (valsi-promptfile-test--tree content "skills/x/SKILL.md"))
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

(ert-deftest valsi-test-promptfile-field-regions-disjoint ()
  "Each field covers its own line, so siblings never overlap (issue #38)."
  (let* ((root (valsi-promptfile-test--tree "---\ne:\ns:\n---" "x.md"))
         (fields (valsi-node-of-type root 'field)))
    (should (equal '((4 . 6) (7 . 9))
                   (mapcar (lambda (f) (cons (valsi-node-beg f) (valsi-node-end f)))
                           fields)))))

;;;; Eager / lazy disclosure split

(ert-deftest valsi-test-promptfile-disclosure-split ()
  "Frontmatter is eager; body sections are lazy."
  (let* ((content "---\nname: x\ndescription: a real description that triggers\n---\n\n# Body\n\ntext\n\n## More\n")
         (root (valsi-promptfile-test--tree content "skills/x/SKILL.md"))
         (fm (car (valsi-node-of-type root 'frontmatter)))
         (sections (valsi-node-of-type root 'section)))
    (should (eq 'eager (valsi-node-prop fm :disclosure)))
    (should (= 2 (length sections)))
    (should (cl-every (lambda (s) (eq 'lazy (valsi-node-prop s :disclosure)))
                      sections))))

(ert-deftest valsi-test-promptfile-no-frontmatter-body-only ()
  "A bare (frontmatter-less) command still parses; no frontmatter node."
  (let* ((content "Summarize this file: $ARGUMENTS\n")
         (root (valsi-promptfile-test--tree content ".claude/commands/sum.md")))
    (should (null (valsi-node-of-type root 'frontmatter)))
    (should (eq 'command (valsi-promptfile-type root)))))

;;;; Argument placeholders (R6)

(ert-deftest valsi-test-promptfile-args ()
  "Command-template argument placeholders are recognized and de-duplicated."
  (let* ((content "---\ndescription: x\n---\n\nDo $ARGUMENTS with $1 and again $1 and $2.\n")
         (root (valsi-promptfile-test--tree content ".claude/commands/c.md")))
    (should (equal '("$ARGUMENTS" "$1" "$2") (valsi-node-prop root :args)))))

;;;; Validation (rung 3)

(ert-deftest valsi-test-promptfile-validate-missing-required ()
  "A skill missing description is flagged."
  (let* ((content "---\nname: x\n---\n\n# X\n")
         (root (valsi-promptfile-test--tree content "skills/x/SKILL.md"))
         (issues (valsi-promptfile--validate-collect root)))
    (should (cl-some (lambda (i) (string-match-p "missing required key: description" i))
                     issues))))

(ert-deftest valsi-test-promptfile-validate-unknown-key-warns ()
  "An unknown key produces a warning, not required-key failure."
  (let* ((content "---\nname: x\ndescription: a genuinely useful trigger sentence\nnonsense: y\n---\n\n# X\n")
         (root (valsi-promptfile-test--tree content "skills/x/SKILL.md"))
         (issues (valsi-promptfile--validate-collect root)))
    (should (cl-some (lambda (i) (string-match-p "unknown key" i)) issues))
    (should-not (cl-some (lambda (i) (string-match-p "missing required" i))
                         issues))))

(ert-deftest valsi-test-promptfile-validate-command-no-frontmatter-ok ()
  "A command has no required keys: a bare template is valid."
  (let* ((content "Do the thing: $ARGUMENTS\n")
         (root (valsi-promptfile-test--tree content ".claude/commands/c.md")))
    (should (null (valsi-promptfile--validate-collect root)))))

(ert-deftest valsi-test-promptfile-validate-weak-description ()
  "A too-short description is flagged as a weak trigger."
  (let* ((content "---\nname: x\ndescription: short\n---\n\n# X\n")
         (root (valsi-promptfile-test--tree content "skills/x/SKILL.md"))
         (issues (valsi-promptfile--validate-collect root)))
    (should (cl-some (lambda (i) (string-match-p "weak match signal" i)) issues))))

(ert-deftest valsi-test-promptfile-validate-clean ()
  "A well-formed skill validates with no issues."
  (let* ((content "---\nname: pdf-tools\ndescription: Extract text and tables from PDF files when the user mentions PDFs.\nlicense: Apache-2.0\n---\n\n# PDF\n")
         (root (valsi-promptfile-test--tree content "skills/pdf/SKILL.md")))
    (should (null (valsi-promptfile--validate-collect root)))))

;;;; YAML scalar forms (issue #63)

(ert-deftest valsi-test-promptfile-block-and-quoted-scalars ()
  "Folded, literal and quoted scalars resolve to their text; empty is missing."
  (let* ((folded (valsi-promptfile-test--tree
                  "---\nname: pdf\ndescription: >\n  Extract text from PDFs when the user\n  asks about PDF files and forms.\n---\nbody\n"
                  "skills/pdf/SKILL.md"))
         (fields (valsi-node-of-type folded 'field)))
    (should (null (valsi-promptfile--validate-collect folded)))
    (should (equal "Extract text from PDFs when the user asks about PDF files and forms."
                   (valsi-promptfile--field folded "description")))
    ;; The block field's region covers its continuation lines, disjoint
    ;; from the next sibling.
    (should (= 2 (length fields)))
    (should (<= (valsi-node-end (nth 0 fields)) (valsi-node-beg (nth 1 fields))))
    (should (< (valsi-node-end (nth 1 fields))
               (valsi-node-end (car (valsi-node-of-type folded 'frontmatter)))))
    (should (> (- (valsi-node-end (nth 1 fields)) (valsi-node-beg (nth 1 fields)))
               50))
    (should (equal "Extract text from PDFs when the user\nasks about PDF files and forms."
                   (valsi-promptfile--field
                    (valsi-promptfile-test--tree
                     "---\nname: pdf\ndescription: |-\n  Extract text from PDFs when the user\n  asks about PDF files and forms.\n---\n"
                     "skills/pdf/SKILL.md")
                    "description")))
    (should (cl-some (lambda (i) (string-match-p "restates name" i))
                     (valsi-promptfile--validate-collect
                      (valsi-promptfile-test--tree
                       "---\nname: pdf\ndescription: \"pdf\"\n---\n"
                       "skills/pdf/SKILL.md"))))
    (should (member "missing required key: name"
                    (valsi-promptfile--validate-collect
                     (valsi-promptfile-test--tree
                      "---\nname:\ndescription: Extract text from PDFs when the user asks about PDFs.\n---\nbody\n"
                      "skills/pdf/SKILL.md"))))))

;;;; Description-as-trigger test-fire (rung 4)

(ert-deftest valsi-test-promptfile-match-score ()
  "The test-fire score reflects query/description keyword overlap."
  (let ((desc "Extract text and tables from PDF files and fill forms"))
    (should (>= (valsi-promptfile--match-score desc "extract tables from a pdf") 0.5))
    (should (= 0.0 (valsi-promptfile--match-score desc "schedule a calendar meeting")))))

;;;; Capabilities

(ert-deftest valsi-test-promptfile-capabilities ()
  "A skill with a description advertises validate + test-fire; a bare file does not."
  (let* ((skill (valsi-promptfile-test--tree
                 "---\nname: x\ndescription: a real trigger sentence here\n---\n\n# X\n"
                 "skills/x/SKILL.md"))
         (bare (valsi-promptfile-test--tree "just prose\n" "notes.md")))
    (should (memq 'validate (valsi-promptfile-capabilities skill)))
    (should (memq 'test-fire (valsi-promptfile-capabilities skill)))
    (should-not (memq 'validate (valsi-promptfile-capabilities bare)))))

;;;; Scaffold template

(ert-deftest valsi-test-promptfile-scaffold-template ()
  "The scaffold SKILL.md template is a valid, parseable skill."
  (let* ((body (valsi-promptfile--skill-template "my-skill"))
         (root (valsi-promptfile-test--tree body "my-skill/SKILL.md")))
    (should (string-match-p "^name: my-skill" body))
    (should (eq 'skill (valsi-promptfile-type root)))
    (should (valsi-node-of-type root 'frontmatter))))

(provide 'valsi-promptfile-test)
;;; valsi-promptfile-test.el ends here

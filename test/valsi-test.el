;;; valsi-test.el --- ERT tests for Valsi -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Recognizer, parse, dialect, capability, and round-trip tests over the real
;; corpus fixtures in test/fixtures/.

;;; Code:

(require 'ert)
(require 'json)
(require 'valsi)
(require 'valsi-agent)
(require 'valsi-plan-review)
(require 'valsi-plan-agent)

(defconst valsi-test--dir
  (file-name-directory (or load-file-name buffer-file-name
                           (expand-file-name "test/valsi-test.el")))
  "Directory of this test file, captured at load time.")

(defun valsi-test--fixture (name)
  "Return the absolute path of fixture NAME."
  (expand-file-name name (expand-file-name "fixtures" valsi-test--dir)))

(defmacro valsi-test--with-file (name &rest body)
  "Run BODY in a temp buffer holding fixture NAME's contents."
  (declare (indent 1))
  `(with-temp-buffer
     (insert-file-contents (valsi-test--fixture ,name))
     (setq buffer-file-name (valsi-test--fixture ,name))
     (unwind-protect (progn ,@body)
       (setq buffer-file-name nil))))

;;;; Recognizer units

(ert-deftest valsi-test-checkbox ()
  (should (eq 'open (plist-get (valsi-parse-checkbox "- [ ] hi") :state)))
  (should (eq 'done (plist-get (valsi-parse-checkbox "- [x] hi") :state)))
  (should (eq 'in-progress (plist-get (valsi-parse-checkbox "- [-] hi") :state)))
  (should (eq 'unknown (plist-get (valsi-parse-checkbox "- [?] hi") :state)))
  (should (null (valsi-parse-checkbox "not a task"))))

(ert-deftest valsi-test-id-and-key ()
  (should (equal "T001" (valsi-parse-id "T001 [P] do")))
  (should (equal "1.2" (valsi-parse-id "1.2 Set up")))
  (should (equal '(1 2) (valsi-parse-sort-key "1.2")))
  (should (equal '(101) (valsi-parse-sort-key "T101")))
  (should (valsi-parse-sort-key< '(1 2) '(1 10)))
  (should (valsi-parse-sort-key< '(1) '(1 1))))

(ert-deftest valsi-test-tags-deps-traces ()
  (should (assoc "P" (valsi-parse-tags "[P] [US1] do")))
  (should (eq 'story (cdr (assoc "US1" (valsi-parse-tags "[P] [US1] do")))))
  (should (equal '("T001" "T002") (valsi-parse-deps "x (depends on T001, T002)")))
  (should (equal '("1.1" "2.1")
                 (valsi-parse-requirements "  _Requirements: 1.1, 2.1_")))
  (should (member "app/x.rb:10"
                  (valsi-parse-pathrefs "at `app/x.rb:10` please"))))

;;;; Parse over corpus

(ert-deftest valsi-test-parse-speckit ()
  (valsi-test--with-file "speckit-real-fragment.md"
    (let* ((root (valsi-plan-parse (buffer-string)))
           (tasks (valsi-node-of-type root 'task)))
      (should (>= (length tasks) 3))
      (should (equal "T001" (valsi-node-prop (car tasks) :id)))
      (should (eq 'speckit (valsi-node-prop root :dialect))))))

(ert-deftest valsi-test-parse-kiro ()
  (valsi-test--with-file "kiro-tasks-example.md"
    (let* ((root (valsi-plan-parse (buffer-string)))
           (tasks (valsi-node-of-type root 'task)))
      (should (> (length tasks) 5))
      (should (eq 'kiro (valsi-node-prop root :dialect)))
      ;; interior task 1 should have children 1.1, 1.2
      (let ((one (cl-find-if (lambda (tk) (equal "1" (valsi-node-prop tk :id)))
                             tasks)))
        (should one)
        (should (valsi-node-of-type one 'task))))))

(ert-deftest valsi-test-effective-state ()
  (valsi-test--with-file "kiro-tasks-example.md"
    (let* ((root (valsi-plan-parse (buffer-string)))
           (one (cl-find-if (lambda (tk) (equal "1" (valsi-node-prop tk :id)))
                            (valsi-node-of-type root 'task))))
      ;; all children open -> interior open
      (should (eq 'open (valsi-plan-effective-state one))))))

;;;; Structure editing (Sprint 4): insert / renumber / add-dep

(ert-deftest valsi-test-plan-insert ()
  "insert-task appends the next Tnnn id in a speckit buffer."
  (with-temp-buffer
    (insert "# Plan\n- [ ] T001 a\n- [ ] T002 b\n")
    (goto-char (point-min))
    (forward-line 2)                     ; on the T002 line
    (valsi-plan-insert-task "c")
    (should (string-match-p "^- \\[ \\] T003 c$" (buffer-string)))
    ;; inserted right after T002, before nothing else
    (should (string-match-p "T002 b\n- \\[ \\] T003 c" (buffer-string)))))

(ert-deftest valsi-test-plan-insert-kiro ()
  "insert-task uses the next integer id in a kiro buffer."
  (with-temp-buffer
    (insert "# Plan\n- [ ] 1 a\n- [ ] 2 b\n")
    (goto-char (point-max))
    (valsi-plan-insert-task "c")
    (should (string-match-p "^- \\[ \\] 3 c$" (buffer-string)))))

(ert-deftest valsi-test-plan-renumber ()
  "renumber normalizes ids to sequential order and rewrites dep refs."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "# Plan\n- [ ] T005 first\n- [ ] T009 second (depends on T005)\n")
    (undo-boundary)
    (valsi-plan-renumber)
    (should (string-match-p "^- \\[ \\] T001 first$" (buffer-string)))
    (should (string-match-p "^- \\[ \\] T002 second (depends on T001)$"
                            (buffer-string)))
    ;; the whole renumber is one undo group -> a single undo reverts it all
    (primitive-undo 1 buffer-undo-list)
    (should (string-match-p "T005 first" (buffer-string)))
    (should (string-match-p "T009 second (depends on T005)" (buffer-string)))))

(ert-deftest valsi-test-plan-renumber-refuses-kiro ()
  "renumber refuses on a non-speckit dialect rather than mangling ids."
  (with-temp-buffer
    (insert "# Plan\n- [ ] 1 a\n- [ ] 2 b\n")
    (should-error (valsi-plan-renumber) :type 'user-error)))

(ert-deftest valsi-test-plan-cycle ()
  "The dependency cycle check is transitive."
  (let* ((content "# Plan\n- [ ] T001 a (depends on T002)\n- [ ] T002 b\n")
         (tasks (valsi-node-of-type (valsi-plan-parse content) 'task)))
    (should (valsi-plan--reaches-p "T001" "T002" tasks))
    (should-not (valsi-plan--reaches-p "T002" "T001" tasks))))

(ert-deftest valsi-test-plan-add-dep-merges ()
  "Adding a dep merges into an existing `depends on' group."
  (with-temp-buffer
    (insert "# Plan\n- [ ] T003 c (depends on T001)\n")
    (goto-char (point-min))
    (forward-line 1)
    (valsi-plan--insert-dep-on-line "T002")
    (should (string-match-p "(depends on T001, T002)" (buffer-string)))))

(ert-deftest valsi-test-plan-complete-with-children ()
  "complete-with-children marks the parent and every descendant done."
  (with-temp-buffer
    (insert "# Plan\n- [ ] 1 parent\n  - [ ] 1.1 a\n  - [ ] 1.2 b\n")
    (goto-char (point-min))
    (forward-line 1)                     ; on "1 parent"
    (valsi-plan-complete-with-children)
    (should (string-match-p "- \\[x\\] 1 parent" (buffer-string)))
    (should (string-match-p "- \\[x\\] 1.1 a" (buffer-string)))
    (should (string-match-p "- \\[x\\] 1.2 b" (buffer-string)))))

(ert-deftest valsi-test-plan-split ()
  "split-task moves the tail of the line into a new numbered task."
  (with-temp-buffer
    (insert "# Plan\n- [ ] T001 do a thing and another\n")
    (goto-char (point-min))
    (forward-line 1)
    (search-forward "and ")              ; point before "another"
    (valsi-plan-split-task)
    (should (string-match-p "- \\[ \\] T001 do a thing and" (buffer-string)))
    (should (string-match-p "- \\[ \\] T002 another" (buffer-string)))))

(ert-deftest valsi-test-plan-promote-demote ()
  "promote-step -> task and demote-task -> step are inverse-ish."
  (with-temp-buffer
    (insert "# Plan\n- [ ] T001 parent\n  - do the sub thing\n")
    (goto-char (point-min))
    (forward-line 2)                     ; on the plain step bullet
    (valsi-plan-promote-step)
    (should (string-match-p "- \\[ \\] T002 do the sub thing" (buffer-string)))
    ;; now demote it back to a step
    (goto-char (point-min))
    (forward-line 2)
    (valsi-plan-demote-task)
    (should (string-match-p "^  - do the sub thing$" (buffer-string)))))

(ert-deftest valsi-test-plan-move-up ()
  "move-task-up swaps a task above its previous sibling."
  (with-temp-buffer
    (insert "# Plan\n- [ ] T001 first\n- [ ] T002 second\n")
    (goto-char (point-min))
    (forward-line 2)                     ; on T002
    (valsi-plan-move-task-up)
    (should (string-match-p "T002 second\n- \\[ \\] T001 first" (buffer-string)))))

(ert-deftest valsi-test-plan-move-dep-guard ()
  "move refuses to place a task above one it depends on."
  (with-temp-buffer
    (insert "# Plan\n- [ ] T001 first\n- [ ] T002 second (depends on T001)\n")
    (goto-char (point-min))
    (forward-line 2)                     ; on T002, which depends on T001
    (should-error (valsi-plan-move-task-up) :type 'user-error)))

(ert-deftest valsi-test-plan-missing-file ()
  "A done task whose manifest path-ref is gone is flagged."
  (let* ((content "# Plan\n- [x] T001 done `no/such/file.el`\n")
         (findings (valsi-plan--missing-file-findings
                    (valsi-plan-parse content) "/tmp")))
    (should (cl-some (lambda (p) (string-match-p "manifest file missing" (cdr p)))
                     findings))))

(ert-deftest valsi-test-plan-lint-issues ()
  "The pure lint function flags dangling deps, duplicates, cycles, and
interior-state contradictions."
  (let* ((content (concat "# Plan\n"
                          "- [ ] T001 a (depends on T999)\n"   ; dangling
                          "- [ ] T002 b (depends on T003)\n"   ; cycle w/ T003
                          "- [ ] T003 c (depends on T002)\n"
                          "- [ ] T002 dup\n"))                 ; duplicate id
         (issues (valsi-plan--lint-issues (valsi-plan-parse content))))
    (should (cl-some (lambda (s) (string-match-p "dangling dep T999" s)) issues))
    (should (cl-some (lambda (s) (string-match-p "duplicate id T002" s)) issues))
    (should (cl-some (lambda (s) (string-match-p "dependency cycle" s)) issues))))

(ert-deftest valsi-test-plan-lint-interior-state ()
  "A parent marked done with an unfinished child is flagged."
  (let* ((content (concat "# Plan\n"
                          "- [x] 1 parent\n"
                          "  - [ ] 1.1 child\n"))
         (issues (valsi-plan--lint-issues (valsi-plan-parse content))))
    (should (cl-some (lambda (s) (string-match-p "marked done but has an unfinished child" s))
                     issues))))

(ert-deftest valsi-test-plan-lint-clean ()
  "A well-formed plan produces no structural issues."
  (let* ((content (concat "# Plan\n"
                          "- [x] T001 a\n"
                          "- [ ] T002 b (depends on T001)\n"))
         (issues (valsi-plan--lint-issues (valsi-plan-parse content))))
    (should (null issues))))

;;;; Cross-artifact (Sprint 5): trace / coverage / staleness

(ert-deftest valsi-test-plan-coverage ()
  "coverage groups tasks by the requirement ids they trace to."
  (let* ((content (concat "# Plan\n"
                          "- [ ] 1 a\n    - _Requirements: 1.1, 2.1_\n"
                          "- [ ] 2 b\n    - _Requirements: 1.1_\n"))
         (cov (valsi-plan--coverage (valsi-plan-parse content))))
    (should (equal '("1" "2") (cdr (assoc "1.1" cov))))
    (should (equal '("1") (cdr (assoc "2.1" cov))))))

(ert-deftest valsi-test-plan-defined-reqs ()
  "Defined requirement ids are scraped from a requirements file."
  (let ((f (make-temp-file "valsi-req" nil ".md"
                           (concat "## Requirement 1\n"
                                   "1.1 WHEN x THEN y\n1.2 WHEN a THEN b\n"
                                   "## Requirement 2\n2.1 foo\n"))))
    (unwind-protect
        (should (equal '("1.1" "1.2" "2.1") (valsi-plan--defined-requirements f)))
      (delete-file f))))

(ert-deftest valsi-test-plan-requirement-anchor ()
  "The requirement anchor matches whole ids, not substrings."
  (should (string-match-p (valsi-plan--requirement-anchor-re "1.1") "see 1.1 here"))
  (should-not (string-match-p (valsi-plan--requirement-anchor-re "1.1") "11.1x")))

(ert-deftest valsi-test-plan-stale ()
  "stale-check flags a task whose path-ref target is newer than the plan."
  (let* ((dir (make-temp-file "valsi-stale" t))
         (plan (expand-file-name "tasks.md" dir))
         (sub (expand-file-name "src" dir))
         (src (expand-file-name "src/impl.el" dir)))
    (unwind-protect
        (progn
          (make-directory sub)
          (with-temp-file plan (insert "# Plan\n- [x] T001 do `src/impl.el`\n"))
          (with-temp-file src (insert ";; code\n"))
          (set-file-times src (time-add (current-time) 100)) ; newer than plan
          (let* ((root (with-temp-buffer (insert-file-contents plan)
                                         (valsi-plan-parse (buffer-string))))
                 (stale (valsi-plan--stale-tasks root plan)))
            (should (assoc "T001" stale))))
      (delete-directory dir t))))

;;;; Capability advertisement (degradation ladder)

(ert-deftest valsi-test-capabilities ()
  (valsi-test--with-file "kiro-tasks-example.md"
    (let ((caps (valsi-plan-capabilities (valsi-plan-parse (buffer-string)))))
      (should (memq 'toggle caps))
      (should (memq 'goto caps))          ; has ids
      (should (memq 'follow caps)))))     ; has traces

;;;; Registry + detection

(ert-deftest valsi-test-registry-detect ()
  (valsi-init)
  (valsi-test--with-file "wild-kiro-awslabs-tasks.md"
    (should (eq 'plan (valsi-registry-detect buffer-file-name (buffer-string))))))

(ert-deftest valsi-test-registry-hot-reload ()
  "grammar/register at runtime is visible with no restart."
  (valsi-init)
  (let ((probe 'valsi-test-probe))
    (should-not (valsi-registry-get probe))
    (valsi-registry-register (list :id probe :name "Probe" :evidence 'emergent
                                  :capabilities '(outline)))
    (should (valsi-registry-get probe))
    (should (member probe (valsi-registry-all)))
    (valsi-registry-unregister probe)))

;;;; Round-trip identity invariant (descriptive grammar)

(ert-deftest valsi-test-roundtrip-identity ()
  "parse -> serialize is the identity: parsing never mutates the buffer."
  (dolist (f (directory-files (valsi-test--fixture ".") t "\\.md\\'"))
    (with-temp-buffer
      (insert-file-contents f)
      (let ((before (buffer-string)))
        (valsi-plan-parse before)
        (valsi-instruction-parse before)
        (valsi-memory-parse before)
        (valsi-changelog-parse before)
        (valsi-decision-parse before)
        (valsi-overview-parse before)
        (should (equal before (buffer-string)))))))

;;;; Extended families

(ert-deftest valsi-test-changelog ()
  (valsi-init)
  (valsi-test--with-file "CHANGELOG.md"
    (should (eq 'changelog
                (valsi-registry-detect buffer-file-name (buffer-string))))
    (let* ((root (valsi-changelog-parse (buffer-string)))
           (rels (valsi-node-of-type root 'release)))
      (should (= 3 (length rels)))
      (should (valsi-node-prop (car rels) :unreleased))
      (should (equal "2026-06-01" (valsi-node-prop (nth 1 rels) :date)))
      (should (memq 'lint (valsi-changelog-capabilities root))))))

(ert-deftest valsi-test-decision ()
  (valsi-init)
  (valsi-test--with-file "adr/0002-pure-elisp-parser.md"
    (should (eq 'decision
                (valsi-registry-detect buffer-file-name (buffer-string))))
    (let* ((root (valsi-decision-parse (buffer-string)))
           (titles (mapcar (lambda (s) (valsi-node-prop s :title))
                           (valsi-node-of-type root 'section))))
      (should (string-match-p "Accepted" (valsi-node-prop root :status)))
      (should (member "Context" titles))
      (should (member "Decision" titles)))))

(ert-deftest valsi-test-overview ()
  (valsi-init)
  (valsi-test--with-file "README.md"
    (should (eq 'overview
                (valsi-registry-detect buffer-file-name (buffer-string))))
    (let ((root (valsi-overview-parse (buffer-string))))
      (should (> (length (valsi-node-of-type root 'section)) 3))
      (should (valsi-node-of-type root 'link)))))

;;;; JSON serialization of the node model (the wire shape)

(ert-deftest valsi-test-node-json ()
  (valsi-test--with-file "speckit-real-fragment.md"
    (let* ((root (valsi-plan-parse (buffer-string)))
           (pl (valsi-node-to-plist root)))
      (should (equal "plan" (plist-get pl :type)))
      (should (vectorp (plist-get pl :children)))
      ;; encodable without error
      (should (stringp (json-encode pl))))))

;;;; Content-parse is offset-based and buffer-independent

(ert-deftest valsi-test-parse-offsets ()
  "A pure content parse yields 0-based offsets, not buffer positions."
  (let* ((content "# Plan\n- [ ] T001 do a thing\n")
         (root (valsi-plan-parse content)))
    (should (= 0 (valsi-node-beg root)))      ; document starts at offset 0
    (should (= (length content) (valsi-node-end root)))
    (let ((task (car (valsi-node-of-type root 'task))))
      (should task)
      ;; task line begins right after "# Plan\n" (offset 7)
      (should (= 7 (valsi-node-beg task))))))

;;;; The proto seam (server request layer)

(ert-deftest valsi-test-proto-lifecycle ()
  "didOpen resolves a grammar + caps; symbols returns an offset tree."
  (valsi-init)
  (valsi-proto-reset)
  (let* ((uri "mem://tasks.md")
         (text "# Plan\n- [ ] T001 [P] do\n- [ ] T002 (depends on T001)\n")
         (open (valsi-proto-request 'artifact/didOpen (list :uri uri :text text))))
    (should (eq 'plan (plist-get open :grammar)))
    (should (memq 'toggle (plist-get open :capabilities)))
    (should (member uri (valsi-proto-open-uris)))
    (let ((tree (valsi-proto-request 'artifact/symbols (list :uri uri))))
      (should (valsi-node-p tree))
      (should (= 0 (valsi-node-beg tree)))     ; server holds offsets
      (should (>= (length (valsi-node-of-type tree 'task)) 2)))
    (valsi-proto-request 'artifact/didClose (list :uri uri))
    (should-not (member uri (valsi-proto-open-uris)))))

(ert-deftest valsi-test-proto-hot-reload ()
  "grammar/register through proto re-resolves already-open documents."
  (valsi-init)
  (valsi-proto-reset)
  (let ((uri "mem://x.custom"))
    (valsi-proto-request 'artifact/didOpen (list :uri uri :text "hello\n"))
    ;; before registering, the doc resolves to the generic grammar
    (should-not (memq 'custom-thing
                      (plist-get (valsi-proto-request 'artifact/capabilities
                                                     (list :uri uri))
                                 :capabilities)))
    ;; register a grammar that claims .custom, then confirm re-resolution
    (valsi-proto-request
     'grammar/register
     (list :spec (list :id 'valsi-test-custom :name "Custom" :evidence 'emergent
                       :match (lambda (uri _text)
                                (if (string-suffix-p ".custom" uri) 10 0))
                       :parse #'valsi-registry--parse-generic
                       :capabilities '(outline narrow custom-thing))))
    (let ((caps (plist-get (valsi-proto-request 'artifact/capabilities
                                               (list :uri uri))
                           :capabilities)))
      (should (memq 'custom-thing caps)))     ; no restart, doc re-resolved
    (valsi-registry-unregister 'valsi-test-custom)
    (valsi-proto-reset)))

;;;; Client offset->buffer translation round-trips node identity

(ert-deftest valsi-test-node-shift-inverse ()
  (let* ((content "# Plan\n- [ ] T001 do\n")
         (tree (valsi-plan-parse content))
         (task (car (valsi-node-of-type tree 'task)))
         (off (valsi-node-beg task)))
    ;; simulate the client: deep-copy + shift into a buffer whose point-min is 1
    (let* ((local (valsi-node-deep-copy tree)))
      (valsi-node-shift local 1)               ; point-min = 1
      (should (= (1+ off)
                 (valsi-node-beg (car (valsi-node-of-type local 'task)))))
      ;; server tree untouched by the client's shift
      (should (= off (valsi-node-beg task))))))

;;;; Agent core (Sprint 6)

(defun valsi-test--echo-tool (sink)
  "Return an echo tool whose executor pushes its :x arg onto SINK (a symbol)."
  (valsi-agent-tool-create
   :name "echo" :description "echo x"
   :args '(:type "object" :properties (:x (:type "string")) :required ["x"])
   :executor (lambda (args)
               (set sink (plist-get args :x))
               (valsi-agent-tool-result-create
                :ok t :content (concat "got " (plist-get args :x))))))

(ert-deftest valsi-test-agent-mock-loop ()
  "The loop drives a mock provider through a tool call to completion."
  (defvar valsi-test--echoed nil)
  (setq valsi-test--echoed nil)
  (let* ((tool (valsi-test--echo-tool 'valsi-test--echoed))
         (provider (valsi-agent-mock-provider-create
                    :script (list
                             (valsi-agent-turn
                              (list (valsi-agent-tool-use-block "id1" "echo"
                                                               '(:x "hi")))
                              'tool_use)
                             (valsi-agent-turn
                              (list (valsi-agent-text-block "all done"))))))
         (messages (valsi-agent-scope (:auto-approve t)
                     (valsi-agent-run
                      :provider provider :model "mock" :system "sys"
                      :tools (list tool)
                      :messages (list (valsi-agent-message
                                       "user"
                                       (list (valsi-agent-text-block "echo hi"))))))))
    (should (equal "hi" valsi-test--echoed))
    ;; a tool_result message was fed back, and the final assistant text lands
    (should (cl-some (lambda (m)
                       (and (equal (plist-get m :role) "assistant")
                            (string-match-p "all done"
                                            (valsi-agent-message-text m))))
                     messages))
    ;; the mock saw two requests (initial + after tool result)
    (should (= 2 (length (valsi-agent-mock-provider-calls provider))))))

(ert-deftest valsi-test-agent-tool-result-split ()
  "A signalled executor error becomes a non-OK result, not a thrown error."
  (let ((tool (valsi-agent-tool-create
               :name "boom" :executor (lambda (_a) (error "kaboom")))))
    (let ((res (valsi-agent-execute-tool tool nil)))
      (should-not (valsi-agent-tool-result-ok res))
      (should (string-match-p "kaboom" (valsi-agent-tool-result-error res))))))

(ert-deftest valsi-test-agent-scope-refuses-tool ()
  "A tool outside the dispatch allow-list is refused, not executed."
  (let ((ran nil)
        (tool (valsi-agent-tool-create
               :name "danger" :executor (lambda (_a) (setq ran t)
                                          (valsi-agent-tool-result-create :ok t)))))
    (valsi-agent-scope (:tools '("safe") :auto-approve t)
      (let ((res (valsi-agent-execute-tool tool nil)))
        (should-not (valsi-agent-tool-result-ok res))
        (should-not ran)))))

(ert-deftest valsi-test-agent-scope-files-and-dryrun ()
  "File scope blocks out-of-scope reads; dry-run makes apply_edit a no-op."
  (valsi-agent-register-builtin-tools)
  (let* ((dir (make-temp-file "valsi-agent" t))
         (f (expand-file-name "in.txt" dir)))
    (unwind-protect
        (progn
          (with-temp-file f (insert "hello world\n"))
          ;; read outside scope -> refused
          (valsi-agent-scope (:files (list "/nope/other.txt"))
            (should-not (valsi-agent-tool-result-ok
                         (valsi-agent-execute-tool (valsi-agent-get-tool "read_file")
                                                  (list :path f)))))
          ;; dry-run edit -> ok but file unchanged
          (valsi-agent-scope (:files (list f) :auto-approve t :dry-run t)
            (let ((res (valsi-agent-execute-tool
                        (valsi-agent-get-tool "apply_edit")
                        (list :path f :old "hello" :new "goodbye"))))
              (should (valsi-agent-tool-result-ok res))
              (should (string-match-p "dry-run"
                                      (valsi-agent-tool-result-content res)))))
          (should (string-match-p "hello world"
                                  (with-temp-buffer (insert-file-contents f)
                                                    (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest valsi-test-agent-session-roundtrip ()
  "A session appends messages as JSONL and reloads them."
  (let* ((root (make-temp-file "valsi-sess" t))
         (s (valsi-agent-session-open "t1" root)))
    (unwind-protect
        (progn
          (valsi-agent-session-append
           s (valsi-agent-message "user" (list (valsi-agent-text-block "hi"))))
          (valsi-agent-session-append
           s (valsi-agent-message "assistant" (list (valsi-agent-text-block "yo"))))
          (should (= 2 (length (valsi-agent-session-messages s))))
          ;; reopen from disk -> same two messages
          (let ((s2 (valsi-agent-session-resume "t1" root)))
            (should (= 2 (length (valsi-agent-session-messages s2))))))
      (delete-directory root t))))

(ert-deftest valsi-test-agent-instructions ()
  "Instruction loading concatenates AGENTS.md nearest-wins (nearest last)."
  (let* ((root (make-temp-file "valsi-instr" t))
         (sub (expand-file-name "a/b" root)))
    (unwind-protect
        (progn
          (make-directory sub t)
          (with-temp-file (expand-file-name "AGENTS.md" root) (insert "ROOTRULE"))
          (with-temp-file (expand-file-name "AGENTS.md" sub) (insert "LEAFRULE"))
          (let ((ctx (valsi-agent-load-instructions sub)))
            (should (string-match-p "ROOTRULE" ctx))
            (should (string-match-p "LEAFRULE" ctx))
            ;; nearest (leaf) appears after root
            (should (< (string-match "ROOTRULE" ctx)
                       (string-match "LEAFRULE" ctx)))))
      (delete-directory root t))))

;;;; Agent auth (Sprint 6, T602) -- pure/structural parts only (no network)

(ert-deftest valsi-test-auth-pkce ()
  "PKCE challenge is deterministic for a verifier and unpadded base64url."
  (let* ((v "test-verifier-string")
         (c (valsi-agent-auth--pkce-challenge v)))
    (should (equal c (valsi-agent-auth--pkce-challenge v))) ; deterministic
    (should-not (string-match-p "=" c))                    ; unpadded
    (should-not (string-match-p "[+/]" c))))               ; url-safe alphabet

(ert-deftest valsi-test-auth-token-type ()
  (should (eq 'api (valsi-agent-auth-token-type "sk-ant-api03-xxx")))
  (should (eq 'setup (valsi-agent-auth-token-type "sk-ant-oat01-xxx")))
  (should (eq 'claude-code (valsi-agent-auth-token-type "cc-xxx")))
  (should (eq 'oauth (valsi-agent-auth-token-type "eyJhbGci"))))

(ert-deftest valsi-test-auth-expiry ()
  (let ((fresh (valsi-agent-auth-credential-create
                :access "a" :expires (+ (float-time) 3600)))
        (soon (valsi-agent-auth-credential-create
               :access "a" :expires (+ (float-time) 60)))
        (none (valsi-agent-auth-credential-create :access "a")))
    (should-not (valsi-agent-auth-expired-p fresh))
    (should (valsi-agent-auth-expired-p soon))   ; within the 5-min skew
    (should (valsi-agent-auth-expired-p none))))  ; unknown expiry -> refresh

(ert-deftest valsi-test-auth-claude-file-parse ()
  "Claude Code's credential JSON (ms expiry, nested key) parses tolerantly."
  (let* ((pl (json-parse-string
              "{\"claudeAiOauth\":{\"accessToken\":\"cc-abc\",\"refreshToken\":\"r1\",\"expiresAt\":4102444800000}}"
              :object-type 'plist :array-type 'list))
         (cred (valsi-agent-auth--from-plist pl 'claude-code)))
    (should (equal "cc-abc" (valsi-agent-auth-credential-access cred)))
    (should (equal "r1" (valsi-agent-auth-credential-refresh cred)))
    ;; ms epoch coerced to seconds
    (should (< (valsi-agent-auth-credential-expires cred) 5e9))))

(ert-deftest valsi-test-auth-extract-code ()
  (should (equal "abc" (valsi-agent-auth--extract-code
                        "http://127.0.0.1:53692/callback?code=abc&state=x")))
  (should (equal "abc" (valsi-agent-auth--extract-code "abc#state123")))
  (should (equal "abc" (valsi-agent-auth--extract-code "  abc  "))))

;;;; Anthropic adapter (Sprint 6, T603) -- request build + response parse

(ert-deftest valsi-test-anthropic-system-preamble ()
  "The OAuth path prefixes the required Claude Code system preamble."
  (let ((oauth (valsi-agent--anthropic-system '(:system "Be terse.") t))
        (key (valsi-agent--anthropic-system '(:system "Be terse.") nil)))
    (should (string-prefix-p "You are Claude Code," oauth))
    (should (string-match-p "Be terse\\." oauth))
    (should (equal "Be terse." key))))

(ert-deftest valsi-test-anthropic-payload ()
  "Payload omits :tools when none, includes them when present."
  (let ((p (valsi-agent-make-anthropic :model "claude-opus-4-8")))
    (should-not (plist-member (valsi-agent--anthropic-payload p '(:messages [])) :tools))
    (should (plist-member
             (valsi-agent--anthropic-payload
              p (list :messages [] :tools (list '(:name "t"))))
             :tools))))

(ert-deftest valsi-test-anthropic-parse-turn ()
  "An Anthropic response maps to a provider-neutral turn; tool_use survives."
  (let* ((resp (json-parse-string
                "{\"role\":\"assistant\",\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"tool_use\",\"id\":\"i1\",\"name\":\"read_file\",\"input\":{\"path\":\"x\"}}]}"
                :object-type 'plist :array-type 'list))
         (turn (valsi-agent--anthropic-parse-turn resp))
         (uses (valsi-agent-turn-tool-uses turn)))
    (should (eq 'tool_use (plist-get turn :stop-reason)))
    (should (= 1 (length uses)))
    (should (equal "read_file" (plist-get (car uses) :name)))))

;;;; Plan x agent (Sprint 7): context bundle, verify, node-diff review

(defconst valsi-test--plan-agent-fixture
  (concat "## Sprint 1\n\n"
          "- [ ] T001 Build the widget at `lisp/widget.el`\n"
          "  - do the thing\n"
          "  **Verify:** `make check` exits 0.\n"
          "- [ ] T002 Wire it up (depends on T001)\n")
  "A small plan exercising files, steps, verify meta, and deps.")

(ert-deftest valsi-test-plan-context-bundle ()
  "The context bundle captures group, files, steps, deps, and verify."
  (let* ((root (valsi-plan-parse valsi-test--plan-agent-fixture))
         (t1 (cl-find "T001" (valsi-node-of-type root 'task)
                      :key (lambda (tk) (valsi-node-prop tk :id)) :test #'equal))
         (bundle (valsi-plan-context-bundle root t1)))
    (should (equal "T001" (plist-get bundle :id)))
    (should (equal "Sprint 1" (plist-get bundle :group)))
    (should (member "lisp/widget.el" (plist-get bundle :files)))
    (should (member "do the thing" (plist-get bundle :steps)))
    (should (string-match-p "make check" (plist-get bundle :verify)))))

(ert-deftest valsi-test-plan-bundle-prompt ()
  "The dispatch prompt mentions the id, files, and verification."
  (let* ((root (valsi-plan-parse valsi-test--plan-agent-fixture))
         (t1 (car (valsi-node-of-type root 'task)))
         (prompt (valsi-plan-bundle->prompt (valsi-plan-context-bundle root t1))))
    (should (string-match-p "T001" prompt))
    (should (string-match-p "lisp/widget.el" prompt))
    (should (string-match-p "Verification: .*make check" prompt))))

(ert-deftest valsi-test-plan-verify-command ()
  "The verification command is extracted from the Verify meta backticks."
  (let* ((root (valsi-plan-parse valsi-test--plan-agent-fixture))
         (t1 (car (valsi-node-of-type root 'task))))
    (should (equal "make check" (valsi-plan--verify-command t1)))))

(ert-deftest valsi-test-plan-node-diff ()
  "The node diff enumerates exactly the changed tasks, keyed by id."
  (let* ((old "## S\n- [ ] T001 a\n- [ ] T002 b\n- [ ] T003 c\n")
         (new "## S\n- [x] T001 a\n- [ ] T002 b changed\n- [ ] T004 d\n")
         (changes (valsi-plan-diff old new)))
    ;; T001 modified (state), T002 modified (desc), T003 removed, T004 added
    (should (= 4 (length changes)))
    (should (cl-find-if (lambda (c) (and (equal (plist-get c :id) "T001")
                                         (eq (plist-get c :kind) 'modified)))
                        changes))
    (should (cl-find-if (lambda (c) (and (equal (plist-get c :id) "T003")
                                         (eq (plist-get c :kind) 'removed)))
                        changes))
    (should (cl-find-if (lambda (c) (and (equal (plist-get c :id) "T004")
                                         (eq (plist-get c :kind) 'added)))
                        changes))))

(ert-deftest valsi-test-plan-review-reject-all ()
  "Applying no changes restores the content byte-identically (reject-all)."
  (let ((old "## S\n- [ ] T001 a\n- [ ] T002 b\n"))
    (should (equal old (valsi-plan-apply-changes old nil)))))

(ert-deftest valsi-test-plan-review-accept-modified ()
  "Accepting a modified change updates exactly that task line."
  (let* ((old "## S\n- [ ] T001 a\n- [ ] T002 b\n")
         (changes (list (list :kind 'modified :id "T001"
                              :old "- [ ] T001 a" :new "- [x] T001 a")))
         (result (valsi-plan-apply-changes old changes)))
    (should (string-match-p "- \\[x\\] T001 a" result))
    (should (string-match-p "- \\[ \\] T002 b" result))))  ; untouched

(ert-deftest valsi-test-plan-distill-done ()
  "Distill produces a done-marking node-diff for the named tasks."
  (let* ((content "## S\n- [ ] T001 a\n- [ ] T002 b\n")
         (changes (valsi-plan-distill-done content '("T001")))
         (result (valsi-plan-apply-changes content changes)))
    (should (= 1 (length changes)))
    (should (string-match-p "- \\[x\\] T001 a" result))
    (should (string-match-p "- \\[ \\] T002 b" result))))

(provide 'valsi-test)
;;; valsi-test.el ends here

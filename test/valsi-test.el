;;; valsi-test.el --- ERT tests for Valsi -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Recognizer, parse, dialect, capability, and round-trip tests over the real
;; corpus fixtures in test/fixtures/.

;;; Code:

(require 'ert)
(require 'json)
(require 'valsi)
(require 'valsi-harness)
(require 'valsi-pi)
(require 'valsi-pi-test)
(require 'valsi-server-test)
(require 'valsi-plan-review)
(require 'valsi-plan-agent)
(require 'valsi-instruction-test)
(require 'valsi-promptfile-test)
(require 'valsi-memory-test)
(require 'valsi-graph-test)
(require 'valsi-perf-test)
(require 'aap-conformance)

;;;; Pi harness

(ert-deftest valsi-test-pi-jsonl-partial-and-correlated ()
  (let* ((events nil)
         (result nil)
         (client (valsi-pi-create
                  :event-functions
                  (list (lambda (event) (push event events))))))
    (puthash "valsi-1"
             (lambda (response error) (setq result (list response error)))
             (valsi-pi-pending client))
    (valsi-pi--consume
     client
     "{\"type\":\"message_update\",\"delta\":\"hel")
    (should-not events)
    (valsi-pi--consume
     client
     "lo\"}\n{\"id\":\"valsi-1\",\"type\":\"response\",")
    (should (equal "hello" (plist-get (car events) :delta)))
    (should-not result)
    (valsi-pi--consume
     client
     "\"command\":\"prompt\",\"success\":true}\n")
    (should (plist-get (car result) :success))
    (should-not (cadr result))
    (should (= 0 (hash-table-count (valsi-pi-pending client))))))

(ert-deftest valsi-test-pi-concurrent-responses-may-arrive-out-of-order ()
  (let ((client (valsi-pi-create))
        results)
    (puthash "valsi-1" (lambda (response error)
                        (push (list 1 response error) results))
             (valsi-pi-pending client))
    (puthash "valsi-2" (lambda (response error)
                        (push (list 2 response error) results))
             (valsi-pi-pending client))
    (valsi-pi--consume
     client
     (concat "{\"id\":\"valsi-2\",\"type\":\"response\","
             "\"command\":\"prompt\",\"success\":true}\n"
             "{\"id\":\"valsi-1\",\"type\":\"response\","
             "\"command\":\"get_state\",\"success\":true,"
             "\"data\":{\"sessionId\":\"out-of-order\"}}\n"))
    (should (equal '(1 2) (mapcar #'car results)))
    (should (cl-every (lambda (result)
                        (and (plist-get (cadr result) :success)
                             (null (caddr result))))
                      results))
    (should (equal "out-of-order" (valsi-harness-session-id client)))
    (should (= 0 (hash-table-count (valsi-pi-pending client))))))

(ert-deftest valsi-test-pi-jsonl-unicode-separators-are-not-frames ()
  (let* ((events nil)
        (client (valsi-pi-create
                 :event-functions
                 (list (lambda (event) (push event events))))))
    (valsi-pi--consume
     client
     (concat "{\"type\":\"message_update\",\"delta\":\"a"
             (string #x2028) "b" (string #x2029) "c\"}\n"))
    (should (= 1 (length events)))
    (should (equal (concat "a" (string #x2028) "b" (string #x2029) "c")
                   (plist-get (car events) :delta)))))

(ert-deftest valsi-test-pi-malformed-record-becomes-event ()
  (let* ((events nil)
        (client (valsi-pi-create
                 :event-functions
                 (list (lambda (event) (push event events))))))
    (valsi-pi--consume client "{broken}\n")
    (should (eq 'protocol-error (plist-get (car events) :type)))))

(ert-deftest valsi-test-pi-real-process-roundtrip-and-exit ()
  (let* ((events nil)
         (result nil)
         (script
          (concat
           "IFS= read -r request\n"
           "printf '%s\\n' "
           "'{\"type\":\"agent_start\"}' "
           "'{\"id\":\"valsi-1\",\"type\":\"response\","
           "\"command\":\"get_state\",\"success\":true,"
           "\"data\":{\"thinkingLevel\":\"medium\","
           "\"isStreaming\":false,\"isCompacting\":false,"
           "\"steeringMode\":\"one-at-a-time\","
           "\"followUpMode\":\"one-at-a-time\","
           "\"sessionId\":\"fake-session\","
           "\"autoCompactionEnabled\":true,\"messageCount\":0,"
           "\"pendingMessageCount\":0}}'\n"))
         (client (valsi-pi-create
                  :program (or (executable-find "sh") "/bin/sh")
                  :arguments (list "-c" script)
                  :event-functions
                  (list (lambda (event) (push event events))))))
    (unwind-protect
        (progn
          (valsi-harness-state
           client
           (lambda (response error) (setq result (list response error))))
          (let ((deadline (+ (float-time) 2)))
            (while (and (not result) (< (float-time) deadline))
              (accept-process-output (valsi-pi-process client) 0.05)))
          (should result)
          (should-not (cadr result))
          (should (equal "fake-session" (valsi-harness-session-id client)))
          (should (cl-find "agent_start" events
                           :key (lambda (event) (plist-get event :type))
                           :test #'equal))
          (let ((deadline (+ (float-time) 2)))
            (while (and (not (cl-find
                              'process-exit events
                              :key (lambda (event) (plist-get event :type))))
                        (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should-not (valsi-harness-live-p client))
          (should (cl-find 'process-exit events
                           :key (lambda (event) (plist-get event :type)))))
      (valsi-harness-stop client))))

(ert-deftest valsi-test-pi-notify-preserves-extension-request-id ()
  (let* ((script
          (concat "IFS= read -r request\n"
                  "printf '%s\\n' \"$request\" >&2\n"))
         (client (valsi-pi-create
                  :program (or (executable-find "sh") "/bin/sh")
                  :arguments (list "-c" script))))
    (unwind-protect
        (progn
          (valsi-harness-notify
           client '(:type "extension_ui_response" :id "pi-ui-id"
                   :cancelled t))
          (let ((deadline (+ (float-time) 2)))
            (while (and (string-empty-p (valsi-pi--stderr-string client))
                        (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (let ((wire (valsi-pi--stderr-string client)))
            (should (string-match-p "\"id\":\"pi-ui-id\"" wire))
            (should-not (string-match-p "\"id\":\"valsi-" wire))))
      (valsi-harness-stop client))))

(ert-deftest valsi-test-pi-abort-command-roundtrip ()
  (let* ((received nil)
         (script
          (concat
           "IFS= read -r request\n"
           "printf '%s\\n' \"$request\" >&2\n"
           "printf '%s\\n' "
           "'{\"id\":\"valsi-1\",\"type\":\"response\","
           "\"command\":\"abort\",\"success\":true}'\n"))
         (client (valsi-pi-create
                  :program (or (executable-find "sh") "/bin/sh")
                  :arguments (list "-c" script))))
    (unwind-protect
        (progn
          (valsi-harness-abort
           client (lambda (response error)
                    (setq received (list response error))))
          (let ((deadline (+ (float-time) 2)))
            (while (and (not received) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should received)
          (should-not (cadr received))
          (should (equal "abort" (plist-get (car received) :command)))
          (let ((deadline (+ (float-time) 2)))
            (while (and (string-empty-p (valsi-pi--stderr-string client))
                        (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should (string-match-p
                   "\"type\":\"abort\"" (valsi-pi--stderr-string client))))
      (valsi-harness-stop client))))

(ert-deftest valsi-test-pi-exit-fails-all-pending-and-reports-stderr ()
  (let* ((events nil)
         (callbacks nil)
         (script
          (concat
           "IFS= read -r request\n"
           "printf '%s\\n' 'fake pi crashed' >&2\n"
           "exit 7\n"))
         (client (valsi-pi-create
                  :program (or (executable-find "sh") "/bin/sh")
                  :arguments (list "-c" script)
                  :event-functions
                  (list (lambda (event) (push event events))))))
    (valsi-harness-prompt
     client "one" (lambda (response error)
                    (push (list response error) callbacks)))
    (valsi-harness-state
     client (lambda (response error)
              (push (list response error) callbacks)))
    (let ((deadline (+ (float-time) 2)))
      (while (and (< (length callbacks) 2) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (should (= 2 (length callbacks)))
    (should (cl-every (lambda (result)
                        (and (null (car result)) (cadr result)))
                      callbacks))
    (should (= 0 (hash-table-count (valsi-pi-pending client))))
    (let ((exit (cl-find 'process-exit events
                         :key (lambda (event) (plist-get event :type)))))
      (should exit)
      (should (= 7 (plist-get exit :code)))
      (should (string-match-p "fake pi crashed"
                              (plist-get exit :stderr))))))

(ert-deftest valsi-test-pi-old-process-failure-does-not-touch-new-requests ()
  (let* ((client (valsi-pi-create))
         (old-process 'old)
         (new-process 'new)
         old-result new-result)
    (puthash "valsi-1"
             (list :process old-process
                   :callback (lambda (response error)
                               (setq old-result (list response error))))
             (valsi-pi-pending client))
    (puthash "valsi-2"
             (list :process new-process
                   :callback (lambda (response error)
                               (setq new-result (list response error))))
             (valsi-pi-pending client))
    (valsi-pi--fail-pending client "old exited" old-process)
    (should (cadr old-result))
    (should-not new-result)
    (should (gethash "valsi-2" (valsi-pi-pending client)))
    (valsi-pi--consume
     client
     "{\"id\":\"valsi-2\",\"type\":\"response\",\"success\":true}\n")
    (should (plist-get (car new-result) :success))
    (should-not (cadr new-result))))

(ert-deftest valsi-test-pi-one-bad-callback-does-not-strand-others ()
  (let ((client (valsi-pi-create))
        called events)
    (setf (valsi-harness-event-functions client)
          (list (lambda (event) (push event events))))
    (puthash "bad" (lambda (_response _error) (error "callback broke"))
             (valsi-pi-pending client))
    (puthash "good" (lambda (_response error) (setq called error))
             (valsi-pi-pending client))
    (valsi-pi--fail-pending client "gone")
    (should called)
    (should (= 0 (hash-table-count (valsi-pi-pending client))))
    (should (cl-find 'callback-error events
                     :key (lambda (event) (plist-get event :type))))))

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
     (list :spec (list :id "valsi-test-custom"
                       :name "Custom" :evidence "emergent"
                       :match (list :uriSuffix ".custom" :score 10)
                       :recognizers []
                       :capabilities ["outline" "narrow" "custom-thing"])))
    (let ((caps (plist-get (valsi-proto-request 'artifact/capabilities
                                               (list :uri uri))
                           :capabilities)))
      (should (memq 'custom-thing caps)))     ; no restart, doc re-resolved
    (valsi-registry-unregister 'valsi-test-custom)
    (valsi-proto-reset)))

(ert-deftest valsi-test-proto-json-registration ()
  "A grammar declaration and its response survive a real JSON round-trip."
  (valsi-init)
  (valsi-proto-reset)
  (let* ((spec (list :id "wire-demo" :name "Wire demo" :evidence "emergent"
                     :match (list :uriSuffix ".wire" :score 10)
                     :recognizers
                     (vector (list :type "marker" :regexp "^MARK: +\\(.*\\)$"
                                   :properties (list :value 1)))
                     :capabilities ["wire-cap"]))
         (request-json (json-serialize (list :spec spec)))
         (params (json-parse-string request-json
                                    :object-type 'plist :array-type 'array))
         (response (valsi-proto-json-request "grammar/register" params))
         (response-json (json-serialize response)))
    (should (stringp response-json))
    (should (equal "wire-demo"
                   (plist-get (json-parse-string response-json
                                                 :object-type 'plist)
                              :id)))
    (let* ((uri "x.wire")
           (text "MARK: hello\n"))
      (valsi-proto-json-request
       "artifact/didOpen" (list :uri uri :text text))
      (let* ((wire-tree (valsi-proto-json-request
                         "artifact/symbols" (list :uri uri)))
             (tree-json (json-serialize wire-tree))
             (decoded (json-parse-string tree-json :object-type 'plist
                                         :array-type 'array))
             (child (aref (plist-get decoded :children) 0)))
        (should (equal "marker" (plist-get child :type)))
        (should (equal "hello"
                       (plist-get (plist-get child :props) :value)))))
    (valsi-registry-unregister 'wire-demo)
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

(ert-deftest valsi-test-plan-block-records-reason ()
  "Blocking a task records the reason without projecting agent UI state."
  (with-temp-buffer
    (insert "- [ ] T1308 Verify resume\n")
    (goto-char (point-min))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "waiting for restart")))
      (valsi-plan-block))
    (should (string-match-p "Blocked: waiting for restart"
                            (buffer-string)))))

(ert-deftest valsi-test-plan-blocked-task-is-not-actionable ()
  "A task with unmet dependencies is neither selected nor dispatched."
  (with-temp-buffer
    (insert "# Tasks\n- [ ] T001 blocked (depends on T999)\n")
    (let ((tree (valsi-plan-parse (buffer-string)))
          (dispatched nil))
      (valsi-node-shift tree (point-min))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'valsi-tree) (lambda () tree))
                ((symbol-function 'valsi-plan-dispatch-task)
                 (lambda () (setq dispatched t))))
        (should-not (valsi-plan-next-actionable))
        (valsi-plan-dispatch-next)
        (should-not dispatched)))))

(ert-deftest valsi-test-plan-review-commands-have-interactive-inputs ()
  "Review supplies input while distill uses the attached harness."
  (should (cadr (interactive-form 'valsi-plan-review-update)))
  (should (interactive-form 'valsi-plan-distill)))

;;;; Artifact application and terminal agents

(ert-deftest valsi-test-app-scans-and-renders-recognized-artifacts ()
  "The project hub summarizes recognized artifacts and ignores ordinary files."
  (let ((root (make-temp-file "valsi-app-" t)))
    (unwind-protect
        (let ((plan (expand-file-name "PLAN.md" root))
              (notes (expand-file-name "notes.txt" root)))
          (write-region "# Plan\n- [ ] T001 ship\n" nil plan nil 'silent)
          (write-region "ordinary project notes\n" nil notes nil 'silent)
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&rest _) 'valsi-test-project))
                    ((symbol-function 'project-root)
                     (lambda (_) root))
                    ((symbol-function 'project-files)
                     (lambda (_) (list plan notes))))
            (let ((entries (valsi-app--scan root)))
              (should (= 1 (length entries)))
              (should (eq 'plan (plist-get (car entries) :grammar)))
              (with-temp-buffer
                (valsi-app-mode)
                (setq valsi-app--root root
                      valsi-app--entries entries
                      valsi-app--compact nil)
                (valsi-app--render)
                (should (search-forward "Plan" nil t))
                (should (search-forward "PLAN.md" nil t))
                (should-not (search-forward "notes.txt" nil t))))))
      (delete-directory root t))))

(ert-deftest valsi-test-terminal-agent-starts-stock-pi-in-project ()
  "Terminal integration launches stock Pi with the declared subscription CLI."
  (let ((root (file-name-as-directory
               (make-temp-file "valsi-agent-" t)))
        captured)
    (unwind-protect
        (cl-letf (((symbol-function 'valsi-terminal-agent--eat) #'ignore)
                  ((symbol-function 'valsi-terminal-agent--ensure-program)
                   (lambda (program _backend) program))
                  ((symbol-function 'eat-make)
                   (lambda (name program startfile &rest args)
                     (setq captured
                           (list name program startfile args
                                 default-directory))
                     (get-buffer-create " *valsi-test-eat*"))))
          (let ((instance
                 (valsi-terminal-agent--start root "primary" 'pi)))
            (should (equal "pi" (nth 1 captured)))
            (should (equal '("--continue" "--provider" "openai-codex"
                            "--model" "gpt-5.5")
                           (seq-take (nth 3 captured) 5)))
            (should (equal "--extension"
                           (nth 5 (nth 3 captured))))
            (should (equal root (nth 4 captured)))
            (should (eq 'pi
                        (valsi-terminal-agent-instance-backend instance)))))
      (when-let* ((buffer (get-buffer " *valsi-test-eat*")))
        (kill-buffer buffer))
      (clrhash valsi-terminal-agent--instances)
      (delete-directory root t))))

(ert-deftest valsi-test-terminal-agent-wheel-controls-emacs-scrollback ()
  "Valsi captures wheel events before a TUI's terminal mouse reporting."
  (with-temp-buffer
    (valsi-terminal-agent-mode 1)
    (should (eq #'mwheel-scroll (key-binding [wheel-up])))
    (should (eq #'mwheel-scroll (key-binding [wheel-down])))
    (should (memq 'valsi-terminal-agent--emulation-map-alist
                  emulation-mode-map-alists))))

(provide 'valsi-test)
;;; valsi-test.el ends here

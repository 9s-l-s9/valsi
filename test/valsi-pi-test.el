;;; valsi-pi-test.el --- Pi RPC lifecycle tests for Valsi -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Process-generation tests kept separate from the general Valsi test corpus.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-harness)
(require 'valsi-pi)

(defconst valsi-pi-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the Pi harness tests.")

(defun valsi-pi-test--fixture (name)
  "Return the Pi 0.80.6 fixture path NAME."
  (expand-file-name name
                    (expand-file-name "fixtures/pi-0.80.6"
                                      valsi-pi-test--directory)))

(defun valsi-pi-test--lines (name)
  "Read nonempty strict-LF JSONL lines from fixture NAME."
  (with-temp-buffer
    (insert-file-contents (valsi-pi-test--fixture name))
    (split-string (buffer-string) "\n" t)))

(defun valsi-pi-test--state-json (id)
  "Return a valid pinned-protocol get_state response for ID."
  (format
   (concat "{\"id\":\"%s\",\"type\":\"response\",\"command\":\"get_state\","
           "\"success\":true,\"data\":{\"thinkingLevel\":\"medium\","
           "\"isStreaming\":false,\"isCompacting\":false,"
           "\"steeringMode\":\"one-at-a-time\","
           "\"followUpMode\":\"one-at-a-time\",\"sessionId\":\"recovered\","
           "\"autoCompactionEnabled\":true,\"messageCount\":0,"
           "\"pendingMessageCount\":0}}")
   id))

(ert-deftest valsi-pi-test-login-targets-subscription-provider ()
  "The default onboarding path names Pi's Codex subscription provider."
  (should
   (equal (valsi-pi--login-input "openai-codex")
          "/valsi-login openai-codex"))
  (should (equal (valsi-pi--login-input "anthropic")
                 "/valsi-login anthropic"))
  (should-error (valsi-pi--login-input "openai-codex\n/quit")
                :type 'user-error))

(ert-deftest valsi-pi-test-auth-status-validates-provider ()
  "The status query uses the audited command and rejects injection."
  (let ((client (valsi-pi-create))
        sent)
    (cl-letf (((symbol-function 'valsi-harness-prompt)
               (lambda (observed message callback)
                 (setq sent (list observed message callback))
                 "request-id")))
      (should
       (equal "request-id"
              (valsi-pi-auth-status client "openai-codex" #'ignore))))
    (should (eq (car sent) client))
    (should (equal (cadr sent) "/valsi-auth-status openai-codex"))
    (should-error
     (valsi-pi-auth-status client "openai-codex\n/quit")
     :type 'user-error)))

(ert-deftest valsi-pi-test-session-contract-uses-pinned-rpc-commands ()
  "Session helpers preserve Pi ownership and exact 0.80.6 field names."
  (let ((client (valsi-pi-create))
        commands)
    (cl-letf (((symbol-function 'valsi-harness-request)
               (lambda (_client command _callback)
                 (push command commands)
                 "request-id")))
      (valsi-pi-get-session-tree client #'ignore)
      (valsi-pi-get-session-entries client #'ignore "entry-1")
      (valsi-pi-switch-session client "/pi/session.jsonl" #'ignore)
      (valsi-pi-fork-session client "entry-2" #'ignore)
      (valsi-pi-set-session-name client "  named session  " #'ignore))
    (should
     (equal
      (nreverse commands)
      '((:type "get_tree")
        (:type "get_entries" :since "entry-1")
        (:type "switch_session" :sessionPath "/pi/session.jsonl")
        (:type "fork" :entryId "entry-2")
        (:type "set_session_name" :name "named session"))))
    (should (eq t (plist-get valsi-pi-session-rpc-capabilities
                             :switch-by-path)))
    (should (eq 'extension
                (plist-get valsi-pi-session-rpc-capabilities
                           :list-sessions)))))

(ert-deftest valsi-pi-test-session-contract-matches-golden-trace ()
  "Session command serialization stays pinned to Pi 0.80.6."
  (let ((requests
         '((:id "valsi-1" :type "get_tree")
           (:id "valsi-2" :type "get_entries" :since "entry-1")
           (:id "valsi-3" :type "switch_session"
                :sessionPath "/pi/session.jsonl")
           (:id "valsi-4" :type "fork" :entryId "entry-2")
           (:id "valsi-5" :type "set_session_name"
                :name "named session"))))
    (should
     (equal
      (mapcar (lambda (request)
                (json-serialize request :null-object nil
                                :false-object :json-false))
              requests)
      (valsi-pi-test--lines "session-requests.jsonl")))))

(ert-deftest valsi-pi-test-session-contract-rejects-invalid-identifiers ()
  "Invalid session inputs never reach Pi's strict JSONL transport."
  (let ((client (valsi-pi-create)))
    (should-error (valsi-pi-get-session-entries client #'ignore "")
                  :type 'user-error)
    (should-error (valsi-pi-switch-session client "" #'ignore)
                  :type 'user-error)
    (should-error (valsi-pi-fork-session client nil #'ignore)
                  :type 'user-error)
    (should-error (valsi-pi-set-session-name client " \t" #'ignore)
                  :type 'user-error)))

(ert-deftest valsi-pi-test-pinned-request-golden-trace ()
  "Valsi emits the command names and field casing pinned by Pi 0.80.6."
  (let ((actual
         (mapcar
          (lambda (request)
            (json-serialize request :null-object nil
                            :false-object :json-false))
          '((:id "valsi-1" :type "get_state")
            (:id "valsi-2" :type "prompt" :message "Inspect PLAN.md"
                 :streamingBehavior "followUp")
            (:id "valsi-3" :type "abort")))))
    (should (equal actual (valsi-pi-test--lines "requests.jsonl")))))

(ert-deftest valsi-pi-test-pinned-response-golden-trace ()
  "The checked-in Pi 0.80.6 trace survives arbitrary process chunking."
  (let ((client (valsi-pi-create))
        callbacks events)
    (setf (valsi-harness-event-functions client)
          (list (lambda (event) (push event events))))
    (dolist (entry '(("valsi-1" "get_state")
                     ("valsi-2" "prompt")
                     ("valsi-3" "abort")))
      (puthash
       (car entry)
       (list :command (cadr entry)
             :callback
             (lambda (response error)
               (push (list response error) callbacks)))
       (valsi-pi-pending client)))
    (let ((trace
           (with-temp-buffer
             (insert-file-contents
              (valsi-pi-test--fixture "responses.jsonl"))
             (buffer-string))))
      ;; Deliberately split within JSON tokens and immediately around U+2028.
      (while (not (string-empty-p trace))
        (let ((width (min (length trace) (1+ (mod (length trace) 17)))))
          (valsi-pi--consume client (substring trace 0 width))
          (setq trace (substring trace width)))))
    (should (= 3 (length callbacks)))
    (should (cl-every (lambda (result)
                        (and (car result) (null (cadr result))))
                      callbacks))
    (should (valsi-pi-protocol-compatible-p client))
    (should (equal "golden-session" (valsi-harness-session-id client)))
    (dolist (type '("agent_start" "message_start" "message_update"
                    "tool_execution_start" "tool_execution_end"
                    "message_end" "agent_end" "agent_settled"))
      (should (cl-find type events
                       :key (lambda (event) (plist-get event :type))
                       :test #'equal)))))

(ert-deftest valsi-pi-test-command-drift-fails-correlated-request ()
  "A response id cannot disguise a changed Pi command contract."
  (let ((client (valsi-pi-create))
        result events)
    (setf (valsi-harness-event-functions client)
          (list (lambda (event) (push event events))))
    (puthash "valsi-1"
             (list :command "get_state"
                   :callback (lambda (response error)
                               (setq result (list response error))))
             (valsi-pi-pending client))
    (valsi-pi--consume
     client
     "{\"id\":\"valsi-1\",\"type\":\"response\",\"command\":\"state\",\"success\":true}\n")
    (should-not (car result))
    (should (string-match-p "command drift"
                            (error-message-string (cadr result))))
    (should (cl-find 'protocol-error events
                     :key (lambda (event) (plist-get event :type))))))

(ert-deftest valsi-pi-test-crlf-framing-fails-pending-request ()
  "The pinned strict-LF transport rejects CRLF without stranding callbacks."
  (let ((client (valsi-pi-create))
        result events)
    (setf (valsi-harness-event-functions client)
          (list (lambda (event) (push event events))))
    (puthash "valsi-1"
             (list :command "get_state"
                   :callback (lambda (response error)
                               (setq result (list response error))))
             (valsi-pi-pending client))
    (valsi-pi--consume client
                      (concat (valsi-pi-test--state-json "valsi-1") "\r\n"))
    (should-not (car result))
    (should (string-match-p "requires LF"
                            (error-message-string (cadr result))))
    (should (= 0 (hash-table-count (valsi-pi-pending client))))
    (should-not (valsi-pi-protocol-compatible-p client))
    (should (cl-find 'protocol-incompatible events
                     :key (lambda (event) (plist-get event :type))))))

(ert-deftest valsi-pi-test-state-capability-drift-fails-probe ()
  "Missing state capabilities fail closed and retain a diagnostic."
  (let ((client (valsi-pi-create))
        result events)
    (setf (valsi-harness-event-functions client)
          (list (lambda (event) (push event events))))
    (puthash "valsi-1"
             (list :command "get_state"
                   :callback (lambda (response error)
                               (setq result (list response error))))
             (valsi-pi-pending client))
    (valsi-pi--consume
     client
     (concat "{\"id\":\"valsi-1\",\"type\":\"response\","
             "\"command\":\"get_state\",\"success\":true,"
             "\"data\":{\"sessionId\":\"drifted\"}}\n"))
    (should-not (car result))
    (should (cadr result))
    (should-not (valsi-pi-protocol-compatible-p client))
    (should (string-match-p "thinkingLevel"
                            (valsi-pi-protocol-error client)))
    (should-not (valsi-harness-session-id client))
    (should (cl-find 'protocol-incompatible events
                     :key (lambda (event) (plist-get event :type))))))

(ert-deftest valsi-pi-test-state-probe-does-not-require-callback ()
  "A fire-and-forget state response is correlated and validates the contract."
  (let ((client (valsi-pi-create))
        events)
    (setf (valsi-harness-event-functions client)
          (list (lambda (event) (push event events))))
    (puthash "valsi-1" '(:command "get_state" :callback nil)
             (valsi-pi-pending client))
    (valsi-pi--consume client (concat (valsi-pi-test--state-json "valsi-1")
                                    "\n"))
    (should (valsi-pi-protocol-compatible-p client))
    (should (= 0 (hash-table-count (valsi-pi-pending client))))
    (should-not
     (cl-find 'protocol-error events
              :key (lambda (event) (plist-get event :type))))))

(ert-deftest valsi-pi-test-deliberate-restart-accepts-new-requests ()
  (let* ((events nil)
         first-result second-result)
    ;; Each generation accepts one record.  The response id is selected by the
    ;; generation marker, allowing the same executable to serve both starts.
    (let* ((marker (make-temp-file "valsi-pi-generation-"))
           (script
            (concat
             "IFS= read -r request\n"
             "if test -s \"$1\"; then id=valsi-2; command=get_state; "
             "else id=valsi-1; command=prompt; printf x >\"$1\"; fi\n"
             "if test \"$command\" = get_state; then\n"
             "printf '%s\\n' '"
             (valsi-pi-test--state-json "'\"$id\"'")
             "'\n"
             "else\n"
             "printf '%s\\n' "
             "'{\"id\":\"'\"$id\"'\",\"type\":\"response\","
             "\"command\":\"prompt\",\"success\":true}'\n"
             "fi\n"
             "sleep 5\n"))
           (client
            (valsi-pi-create
             :program (or (executable-find "sh") "/bin/sh")
             :arguments (list "-c" script "valsi-pi-test" marker)
             :policy-gate nil
             :event-functions
             (list (lambda (event) (push event events))))))
      (unwind-protect
          (progn
            (valsi-harness-prompt
             client "before restart"
             (lambda (response error)
               (setq first-result (list response error))))
            (let ((deadline (+ (float-time) 2)))
              (while (and (not first-result) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (plist-get (car first-result) :success))
            (valsi-pi-restart client)
            (valsi-harness-state
             client
             (lambda (response error)
               (setq second-result (list response error))))
            (let ((deadline (+ (float-time) 2)))
              (while (and (not second-result) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (plist-get (car second-result) :success))
            (should-not (cadr second-result))
            (should (valsi-harness-live-p client))
            (should
             (cl-find-if
              (lambda (event)
                (and (eq 'process-exit (plist-get event :type))
                     (plist-get event :deliberate)))
              events)))
        (valsi-harness-stop client)
        (delete-file marker)))))

(ert-deftest valsi-pi-test-unexpected-exit-recovers-on-next-request ()
  "A crash fails its request exactly once; the next request starts fresh Pi."
  (let* ((marker (make-temp-file "valsi-pi-crash-generation-"))
         (events nil)
         crashed recovered)
    (let* ((script
            (concat
             "IFS= read -r request\n"
             "if test -s \"$1\"; then\n"
             "printf '%s\\n' '" (valsi-pi-test--state-json "valsi-2") "'\n"
             "sleep 5\n"
             "else\n"
             "printf x >\"$1\"\n"
             "printf '%s\\n' 'simulated crash' >&2\n"
             "exit 23\n"
             "fi\n"))
           (client
            (valsi-pi-create
             :program (or (executable-find "sh") "/bin/sh")
             :arguments (list "-c" script "valsi-pi-test" marker)
             :policy-gate nil
             :event-functions
             (list (lambda (event) (push event events))))))
      (unwind-protect
          (progn
            (valsi-harness-prompt
             client "crash"
             (lambda (response error)
               (setq crashed (list response error))))
            (let ((deadline (+ (float-time) 2)))
              (while (and (not crashed) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should-not (car crashed))
            (should (cadr crashed))
            (should-not (valsi-harness-live-p client))
            (valsi-harness-state
             client
             (lambda (response error)
               (setq recovered (list response error))))
            (let ((deadline (+ (float-time) 2)))
              (while (and (not recovered) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (plist-get (car recovered) :success))
            (should-not (cadr recovered))
            (should (valsi-pi-protocol-compatible-p client))
            (should (equal "recovered" (valsi-harness-session-id client)))
            (let ((exit
                   (cl-find-if
                    (lambda (event)
                      (and (eq 'process-exit (plist-get event :type))
                           (= 23 (plist-get event :code))))
                    events)))
              (should exit)
              (should-not (plist-get exit :deliberate))
              (should (string-match-p "simulated crash"
                                      (plist-get exit :stderr)))))
        (valsi-harness-stop client)
        (delete-file marker)))))

(ert-deftest valsi-pi-test-policy-json-fails-closed-and-is-private ()
  "Empty allow-lists serialize as empty arrays, never missing authority."
  (let* ((directory (make-temp-file "valsi-pi-project-" t))
         (client (valsi-pi-create :directory directory))
         (path (valsi-pi-set-policy client "T1307:test" nil nil t))
         (object (json-parse-string
                  (with-temp-buffer
                    (insert-file-contents path)
                    (buffer-string))
                  :object-type 'plist :array-type 'list
                  :false-object :json-false)))
    (unwind-protect
        (progn
          (should (equal (plist-get object :dispatchId) "T1307:test"))
          (should (equal (plist-get object :tools) nil))
          (should (equal (plist-get object :files) nil))
          (should (eq (plist-get object :dryRun) t))
          (should (> (plist-get object :expiresAt)
                     (floor (* 1000 (float-time)))))
          (should (= (logand (file-modes path) #o777) #o600)))
      (when (file-exists-p path) (delete-file path))
      (delete-directory directory))))

(ert-deftest valsi-pi-test-command-loads-only-audited-extension ()
  "Pi discovery is disabled while Valsi's explicit extension remains loaded."
  (let* ((extension (make-temp-file "valsi-pi-extension-" nil ".ts"))
         (valsi-pi-extension-file extension)
         (client (valsi-pi-create))
         (command (valsi-pi--command client)))
    (unwind-protect
        (progn
          (should (member "--continue" command))
          (should (equal (cadr (member "--provider" command))
                         "openai-codex"))
          (should (equal (cadr (member "--model" command)) "gpt-5.5"))
          (should (member "--no-extensions" command))
          (should (equal (cadr (member "--extension" command)) extension)))
      (delete-file extension))))

(ert-deftest valsi-pi-test-discovers-installed-extension-before-source ()
  "Installed data beside the library is preferred to checkout fallback."
  (let* ((root (make-temp-file "valsi-pi-installed-" t))
         (library (expand-file-name "valsi-pi.el" root))
         (extension (expand-file-name "valsi-pi-extension/index.ts" root))
         (valsi-pi-extension-file nil))
    (make-directory (file-name-directory extension) t)
    (write-region "" nil library nil 'silent)
    (write-region "" nil extension nil 'silent)
    (unwind-protect
        (cl-letf (((symbol-function 'locate-library)
                   (lambda (&rest _) library)))
          (should (equal (valsi-pi--extension-file) extension)))
      (delete-directory root t))))

(ert-deftest valsi-pi-test-live-pinned-extension-smoke ()
  "A discoverable Pi starts in RPC mode with the audited deny-all gate."
  (let ((pi (executable-find valsi-pi-program)))
    (skip-unless pi)
    (let* ((client (valsi-pi-create :program pi))
           result)
      (unwind-protect
          (progn
            (valsi-harness-state
             client
             (lambda (response error)
               (setq result (list response error))))
            (let ((deadline (+ (float-time) 10)))
              (while (and (not result) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should result)
            (ert-info ((format "Pi stderr: %s"
                               (valsi-pi--stderr-string client)))
              (should-not (cadr result)))
            (should (plist-get (car result) :success))
            (should (valsi-harness-live-p client))
            (should (member "--no-extensions" (process-command
                                               (valsi-pi-process client))))
            (should (file-readable-p (valsi-pi-policy-file client))))
        (valsi-harness-stop client)
        (when (and (valsi-pi-policy-file client)
                   (file-exists-p (valsi-pi-policy-file client)))
          (delete-file (valsi-pi-policy-file client)))))))

(provide 'valsi-pi-test)
;;; valsi-pi-test.el ends here

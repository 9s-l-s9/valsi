;;; valsi-pi.el --- Pi JSONL RPC backend for Valsi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Process-safe client for Pi's `--mode rpc'.  It uses LF-only framing,
;; correlates responses by id, sends unsolicited records to the harness event
;; stream, and fails every outstanding request if the subprocess exits.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'valsi-harness)

(defcustom valsi-pi-program "pi"
  "Pi executable used by `valsi-pi-create'."
  :type 'file
  :group 'valsi-harness)

(defcustom valsi-pi-default-arguments
  '("--mode" "rpc" "--continue"
    "--provider" "openai-codex" "--model" "gpt-5.5")
  "Arguments passed to the Pi executable.
Production starts continue the most recent Pi session for the project, so Pi
remains the sole session owner across Emacs restarts.  The pinned default
explicitly selects Pi 0.80.6's ChatGPT-backed Codex provider and model; users
who intentionally choose another provider may customize this complete list."
  :type '(repeat string)
  :group 'valsi-harness)

(defconst valsi-pi--source-extension-file
  (let ((library-directory
         (file-name-directory (or load-file-name buffer-file-name))))
    (expand-file-name "../extensions/valsi-pi/index.ts" library-directory))
  "Source-checkout location of the audited Valsi Pi extension.")

(defcustom valsi-pi-extension-file nil
  "Explicit path to the audited Valsi Pi policy extension.
Nil discovers an installed extension beside `valsi-pi.el', then falls back to
the source checkout.  This is a file rather than a Pi-installed extension so
Valsi can start Pi with extension discovery disabled."
  :type '(choice (const :tag "Discover" nil) file)
  :group 'valsi-harness)

(defcustom valsi-pi-policy-lifetime 3600
  "Seconds before a dispatch policy expires and fails closed."
  :type 'integer
  :group 'valsi-harness)

(defcustom valsi-pi-approval-timeout 120
  "Seconds an extension tool approval may remain unanswered."
  :type 'integer
  :group 'valsi-harness)

(defconst valsi-pi-protocol-version "pi-rpc/0.80.6"
  "Pinned Pi RPC contract against which this client is tested.")

(defconst valsi-pi--required-state-fields
  '(:thinkingLevel :isStreaming :isCompacting :steeringMode :followUpMode
    :sessionId :autoCompactionEnabled :messageCount :pendingMessageCount)
  "Fields from Pi 0.80.6 `get_state' consumed by the Valsi workflow.")

(defconst valsi-pi-session-rpc-capabilities
  '(:current-tree t :current-entries t :fork t :rename t :compact t
    :switch-by-path t :list-sessions extension)
  "Session operations exposed by pinned Pi 0.80.6 and Valsi's audited extension.
Core RPC can switch to an exact path but cannot enumerate sessions.  The
`extension' value means Pi's own `SessionManager.list' supplies that operation;
Valsi does not scan the store or maintain a second index.")

(defcustom valsi-pi-session-list-timeout 10
  "Seconds to wait for the audited extension's session-list response."
  :type 'integer
  :group 'valsi-harness)

(cl-defstruct (valsi-pi
               (:include valsi-harness)
               (:constructor valsi-pi--create))
  program arguments directory process stderr-buffer policy-gate
  policy-file extension-file policy-owner
  (pending (make-hash-table :test #'equal))
  (session-list-pending (make-hash-table :test #'equal))
  (receive-buffer "")
  (sequence 0)
  protocol-compatible-p protocol-error session)

(cl-defun valsi-pi-create (&key
                              (program valsi-pi-program)
                              (arguments valsi-pi-default-arguments)
                              (directory default-directory)
                              (policy-gate t)
                              event-functions)
  "Create a stopped Pi backend.
PROGRAM and ARGUMENTS select the command, DIRECTORY its working directory, and
EVENT-FUNCTIONS receive unsolicited records and lifecycle events.  POLICY-GATE
loads Valsi's audited fail-closed extension; tests and non-Pi adapters may
explicitly disable it."
  (valsi-pi--create :program program :arguments arguments
                   :directory directory :policy-gate policy-gate
                   :event-functions event-functions))

(defun valsi-pi--extension-file ()
  "Return the readable audited extension entry point, or signal an error."
  (let* ((library (or (locate-library "valsi-pi")
                      valsi-pi--source-extension-file))
         (installed (and library
                         (expand-file-name
                          "valsi-pi-extension/index.ts"
                          (file-name-directory library))))
         (path (or valsi-pi-extension-file
                   (and installed (file-readable-p installed) installed)
                   (and (file-readable-p valsi-pi--source-extension-file)
                        valsi-pi--source-extension-file))))
    (unless (and path (file-readable-p path))
      (error "Valsi audited Pi extension is unavailable"))
    (expand-file-name path)))

(defun valsi-pi--ensure-policy-file (client)
  "Return CLIENT's policy path, creating a deny-all policy when needed."
  (or (valsi-pi-policy-file client)
      (let ((path (make-temp-file "valsi-pi-policy-" nil ".json")))
        (set-file-modes path #o600)
        (setf (valsi-pi-policy-file client) path)
        (valsi-pi-set-policy client "startup:deny-all" nil nil t)
        path)))

(defun valsi-pi--policy-object (client dispatch-id tools files dry-run)
  "Build CLIENT's JSON policy for DISPATCH-ID, TOOLS, FILES, and DRY-RUN."
  (list :version 1
        :dispatchId dispatch-id
        :cwd (file-truename
              (file-name-as-directory
               (expand-file-name (valsi-pi-directory client))))
        :tools (vconcat (or tools nil))
        :files (vconcat (or files nil))
        :dryRun (if dry-run t :json-false)
        :expiresAt (+ (floor (* 1000 (float-time)))
                      (* 1000 valsi-pi-policy-lifetime))
        :approvalTimeoutMs (* 1000 valsi-pi-approval-timeout)))

(defun valsi-pi--atomic-write-json (path object)
  "Atomically replace PATH with JSON serialization of OBJECT at mode 0600."
  (let ((temporary (make-temp-file
                    (expand-file-name ".valsi-pi-policy-" (file-name-directory path))
                    nil ".json")))
    (unwind-protect
        (progn
          (set-file-modes temporary #o600)
          (with-temp-file temporary
            (set-buffer-file-coding-system 'utf-8-unix)
            (insert (json-serialize object :null-object nil
                                    :false-object :json-false))
            (insert "\n"))
          (rename-file temporary path t)
          (set-file-modes path #o600))
      (when (file-exists-p temporary)
        (delete-file temporary)))))

(defun valsi-pi-set-policy (client dispatch-id tools files &optional dry-run)
  "Install CLIENT's next fail-closed dispatch policy atomically.
DISPATCH-ID identifies the authority in approval prompts.  TOOLS and FILES are
explicit allow-lists; nil therefore permits nothing.  DRY-RUN denies every
mutating call before execution."
  (unless (and (stringp dispatch-id) (not (string-empty-p dispatch-id)))
    (error "Valsi Pi policy requires a dispatch id"))
  (let ((path (or (valsi-pi-policy-file client)
                  (let ((new (make-temp-file "valsi-pi-policy-" nil ".json")))
                    (setf (valsi-pi-policy-file client) new)
                    new))))
    (valsi-pi--atomic-write-json
     path (valsi-pi--policy-object client dispatch-id tools files dry-run))
    path))

(defun valsi-pi-claim-policy (client owner)
  "Claim CLIENT's policy authority for nonempty OWNER.
Only one live prompt or plan dispatch may replace the policy at a time."
  (unless (and (stringp owner) (not (string-empty-p owner)))
    (error "Valsi Pi policy owner must be a nonempty string"))
  (when (valsi-pi-policy-owner client)
    (user-error "Pi policy is still owned by %s; settle or abort it first"
                (valsi-pi-policy-owner client)))
  (setf (valsi-pi-policy-owner client) owner)
  owner)

(defun valsi-pi-release-policy (client owner)
  "Release CLIENT's policy authority when it is still owned by OWNER."
  (when (equal owner (valsi-pi-policy-owner client))
    (setf (valsi-pi-policy-owner client) nil)
    t))

(defun valsi-pi--command (client)
  "Return the complete audited subprocess command for CLIENT."
  (append
   (list (valsi-pi-program client))
   (valsi-pi-arguments client)
   (when (valsi-pi-policy-gate client)
     (let ((extension (valsi-pi--extension-file)))
       (setf (valsi-pi-extension-file client) extension)
       (list "--no-extensions" "--extension" extension)))))

(cl-defmethod valsi-harness-live-p ((client valsi-pi))
  "Return non-nil when CLIENT's Pi subprocess is live."
  (process-live-p (valsi-pi-process client)))

(cl-defmethod valsi-harness-session-id ((client valsi-pi))
  "Return CLIENT's last observed Pi session id."
  (valsi-pi-session client))

(cl-defmethod valsi-harness-start ((client valsi-pi))
  "Start CLIENT's Pi subprocess unless it is already live."
  (unless (valsi-harness-live-p client)
    (let* ((default-directory (file-name-as-directory
                               (expand-file-name (valsi-pi-directory client))))
           (policy-file (and (valsi-pi-policy-gate client)
                             (valsi-pi--ensure-policy-file client)))
           (process-environment
            (if policy-file
                (cons (concat "Valsi_PI_POLICY_FILE=" policy-file)
                      process-environment)
              process-environment))
           (stderr (generate-new-buffer " *valsi-pi-stderr*"))
           (process
            (make-process
             :name "valsi-pi"
             :command (valsi-pi--command client)
             :coding '(utf-8-unix . utf-8-unix)
             :connection-type 'pipe
             :noquery t
             :stderr stderr
             :filter #'valsi-pi--process-filter
             :sentinel #'valsi-pi--process-sentinel)))
      (set-process-query-on-exit-flag process nil)
      (process-put process 'valsi-pi-client client)
      (process-put process 'valsi-pi-deliberate-stop nil)
      (process-put process 'valsi-pi-stderr-buffer stderr)
      (setf (valsi-pi-process client) process
            (valsi-pi-stderr-buffer client) stderr
            (valsi-pi-receive-buffer client) "")
      (valsi-harness-emit client (list :type 'started :process process))))
  client)

(cl-defmethod valsi-harness-stop ((client valsi-pi))
  "Deliberately stop CLIENT and fail its pending requests."
  (let ((process (valsi-pi-process client)))
    (when (process-live-p process)
      (process-put process 'valsi-pi-deliberate-stop t)
      (delete-process process))
    (setf (valsi-pi-process client) nil)
    (setf (valsi-pi-policy-owner client) nil)
    (valsi-pi--fail-pending client "Pi stopped" process)
    (valsi-pi--fail-session-lists client "Pi stopped" process)
    (valsi-harness-emit client (list :type 'stopped)))
  client)

(defun valsi-pi-restart (client)
  "Deliberately restart CLIENT and return it.
Requests sent to the old process fail before the replacement starts.  A late
sentinel from the old process cannot affect requests sent to the replacement."
  (valsi-harness-stop client)
  (valsi-harness-start client))

(cl-defmethod valsi-harness-request ((client valsi-pi) command callback)
  "Send COMMAND through CLIENT and arrange CALLBACK correlation."
  (unless (valsi-harness-live-p client)
    (valsi-harness-start client))
  (let* ((id (format "valsi-%d" (cl-incf (valsi-pi-sequence client))))
         (request (copy-sequence command)))
    (setq request (plist-put request :id id))
    ;; Track even fire-and-forget commands: their response still establishes
    ;; protocol compatibility and must not appear as an unmatched record.
    (puthash id (list :callback callback
                      :command (plist-get command :type)
                      :process (valsi-pi-process client))
             (valsi-pi-pending client))
    (condition-case err
        (process-send-string
         (valsi-pi-process client)
         (concat (json-serialize request :null-object nil
                                 :false-object :json-false)
                 "\n"))
      (error
       (remhash id (valsi-pi-pending client))
       (when callback (valsi-pi--call-callback client callback nil err))
       (signal (car err) (cdr err))))
    id))

(defun valsi-pi--require-session-client (client)
  "Require CLIENT to be a Pi session authority."
  (unless (valsi-pi-p client)
    (user-error "Pi session operations require a Pi harness"))
  client)

(defun valsi-pi--session-request (client command callback)
  "Send Pi session COMMAND through CLIENT and normalize errors for CALLBACK."
  (valsi-harness-request
   (valsi-pi--require-session-client client) command
   (and callback
        (lambda (response transport-error)
          (if (or transport-error
                  (and response (not (eq t (plist-get response :success)))))
              (funcall callback nil
                       (or transport-error
                           (list 'error
                                 (or (plist-get response :error)
                                     "Pi session operation failed"))))
            (funcall callback response nil))))))

(defun valsi-pi-get-session-tree (client callback)
  "Request CLIENT's authoritative current-session tree via CALLBACK."
  (valsi-pi--session-request client '(:type "get_tree") callback))

(defun valsi-pi-get-session-entries (client callback &optional since)
  "Request CLIENT's authoritative session entries via CALLBACK.
When SINCE is non-nil, Pi returns only entries appended after that entry id."
  (unless (or (null since)
              (and (stringp since) (not (string-empty-p since))))
    (user-error "Pi session entry id must be a nonempty string"))
  (valsi-pi--session-request
   client
   (append '(:type "get_entries") (and since (list :since since)))
   callback))

(defun valsi-pi--finish-session-list (client token response error)
  "Finish CLIENT's session-list TOKEN with RESPONSE or ERROR."
  (when-let* ((entry (gethash token (valsi-pi-session-list-pending client))))
    (remhash token (valsi-pi-session-list-pending client))
    (when-let* ((timer (plist-get entry :timer)))
      (cancel-timer timer))
    (when-let* ((callback (plist-get entry :callback)))
      (valsi-pi--call-callback client callback response error))))

(defun valsi-pi--fail-session-lists (client reason &optional process)
  "Fail CLIENT session-list requests associated with PROCESS using REASON.
When PROCESS is nil, fail every pending list request."
  (let (tokens)
    (maphash (lambda (token entry)
               (when (or (null process)
                         (eq process (plist-get entry :process)))
                 (push token tokens)))
             (valsi-pi-session-list-pending client))
    (dolist (token tokens)
      (valsi-pi--finish-session-list client token nil (list 'error reason)))))

(defun valsi-pi-list-sessions (client callback)
  "List CLIENT's project sessions through Pi's authoritative SDK.
CALLBACK receives a response whose `:data' contains `:sessions'.  The audited
extension invokes `SessionManager.list'; Emacs never reads Pi's session files."
  (valsi-pi--require-session-client client)
  (unless (valsi-harness-live-p client)
    (valsi-harness-start client))
  (let* ((token
          (substring
           (secure-hash
            'sha256
            (format "%s:%s:%s"
                    (float-time) (cl-incf (valsi-pi-sequence client)) (random)))
           0 24))
         (timer
          (run-at-time
           valsi-pi-session-list-timeout nil
           (lambda ()
             (valsi-pi--finish-session-list
              client token nil
              (list 'error "Pi session listing timed out"))))))
    (puthash token (list :callback callback :timer timer
                         :process (valsi-pi-process client))
             (valsi-pi-session-list-pending client))
    (valsi-harness-prompt
     client (format "/valsi-sessions %s" token)
     (lambda (_response error)
       (when error
         (valsi-pi--finish-session-list client token nil error))))
    token))

(defun valsi-pi-switch-session (client session-path callback)
  "Ask CLIENT to switch to exact Pi SESSION-PATH, reporting to CALLBACK.
Pinned Pi has no session-list RPC, so callers must obtain the path from the
user rather than inspecting or mirroring Pi's private session store."
  (unless (and (stringp session-path) (not (string-empty-p session-path)))
    (user-error "Pi session path must be a nonempty string"))
  (valsi-pi--session-request client
                            (list :type "switch_session"
                                  :sessionPath session-path)
                            callback))

(defun valsi-pi-fork-session (client entry-id callback)
  "Ask CLIENT to fork its current session at ENTRY-ID via CALLBACK."
  (unless (and (stringp entry-id) (not (string-empty-p entry-id)))
    (user-error "Pi session entry id must be a nonempty string"))
  (valsi-pi--session-request client
                            (list :type "fork" :entryId entry-id)
                            callback))

(defun valsi-pi-set-session-name (client name callback)
  "Set CLIENT's Pi-owned current session display NAME via CALLBACK."
  (unless (and (stringp name) (not (string-empty-p (string-trim name))))
    (user-error "Pi session name must be nonempty"))
  (valsi-pi--session-request client
                            (list :type "set_session_name"
                                  :name (string-trim name))
                            callback))

(cl-defmethod valsi-harness-notify ((client valsi-pi) message)
  "Send uncorrelated protocol MESSAGE through CLIENT unchanged."
  (unless (valsi-harness-live-p client)
    (valsi-harness-start client))
  (process-send-string
   (valsi-pi-process client)
   (concat (json-serialize message :null-object nil
                           :false-object :json-false)
           "\n")))

;; Keep this construction separate so onboarding behavior is testable without
;; starting an interactive Pi process or touching its credential store.
(defun valsi-pi--login-input (provider)
  "Return the audited extension command that logs in to PROVIDER."
  (unless (and (stringp provider)
               (string-match-p "\\`[[:alnum:]_.-]+\\'" provider))
    (user-error "Invalid Pi provider identifier: %S" provider))
  (format "/valsi-login %s" provider))

(defun valsi-pi-auth-status (client provider &optional callback)
  "Ask CLIENT for PROVIDER's non-secret Pi authentication status.
CALLBACK receives the generic command acknowledgement.  The authoritative
status arrives as a `valsi-auth-status' extension UI event."
  (valsi-harness-prompt
   client
   (format "/valsi-auth-status %s"
           (progn
             (unless (and (stringp provider)
                          (string-match-p "\\`[[:alnum:]_.-]+\\'" provider))
               (user-error "Invalid Pi provider identifier: %S" provider))
             provider))
   callback))

(defun valsi-pi--process-filter (process chunk)
  "Consume JSONL CHUNK emitted by PROCESS."
  (let ((client (process-get process 'valsi-pi-client)))
    (when client (valsi-pi--consume client chunk))))

(defun valsi-pi--consume (client chunk)
  "Consume a possibly partial JSONL CHUNK for CLIENT."
  (let* ((text (concat (valsi-pi-receive-buffer client) chunk))
         (start 0)
         newline)
    (while (setq newline (string-match "\n" text start))
      (let ((line (substring text start newline)))
        (cond
         ((string-suffix-p "\r" line)
          (let ((message
                 (format "%s transport requires LF, received CRLF"
                         valsi-pi-protocol-version)))
            (setf (valsi-pi-protocol-compatible-p client) nil
                  (valsi-pi-protocol-error client) message)
            (valsi-pi--fail-pending client message)
            (valsi-harness-emit
             client (list :type 'protocol-incompatible
                          :protocol valsi-pi-protocol-version
                          :line line :error message))))
         ((not (string-empty-p line))
          (valsi-pi--handle-line client line))))
      (setq start (1+ newline)))
    (setf (valsi-pi-receive-buffer client) (substring text start))))

(defun valsi-pi--handle-line (client line)
  "Decode and dispatch one JSON LINE for CLIENT."
  (condition-case err
      (let* ((record (json-parse-string
                      line :object-type 'plist :array-type 'list
                      :null-object nil :false-object :json-false))
             (type (plist-get record :type))
             (id (plist-get record :id)))
        (if (and (equal type "response") id)
            (let* ((entry (gethash id (valsi-pi-pending client)))
                   (callback (valsi-pi--pending-callback entry))
                   (expected-command (valsi-pi--pending-command entry))
                   (actual-command (plist-get record :command))
                   (mismatch
                    (and expected-command
                         (not (equal expected-command actual-command))))
                   (state-error
                    (and expected-command
                         (not mismatch)
                         (equal actual-command "get_state")
                         (plist-get record :success)
                         (valsi-pi--accept-state client record))))
              (when entry
                (remhash id (valsi-pi-pending client))
                (when callback
                  (if (or mismatch state-error)
                      (valsi-pi--call-callback
                       client callback nil
                       (list 'error
                             (or state-error
                                 (format
                                  "Pi RPC command drift: expected %s, got %s"
                                  expected-command actual-command))))
                    (valsi-pi--call-callback client callback record nil))))
              (unless entry
                (valsi-harness-emit
                 client (list :type 'protocol-error
                              :record record
                              :error (format "Unmatched response id %s" id))))
              (when mismatch
                (valsi-harness-emit
                 client (list :type 'protocol-error :record record
                              :error
                              (format "Response %s expected command %s, got %s"
                                      id expected-command actual-command))))
              ;; Older callers/tests may put a plain callback in `pending'.
              ;; Preserve their session tracking, but only a real request entry
              ;; carrying its expected command can establish compatibility.
              (when (and (not expected-command)
                         (equal actual-command "get_state")
                         (plist-get record :success))
                (setf (valsi-pi-session client)
                      (plist-get (plist-get record :data) :sessionId))))
          (progn
            (valsi-pi--accept-session-list client record)
            (valsi-harness-emit client record))))
    (error
     (valsi-harness-emit
      client (list :type 'protocol-error :line line
                   :error (error-message-string err))))))

(defun valsi-pi--process-sentinel (process event)
  "Report PROCESS state change EVENT and fail requests on exit."
  (let ((client (process-get process 'valsi-pi-client)))
    (when (and client (not (process-live-p process)))
      (when (eq process (valsi-pi-process client))
        (setf (valsi-pi-process client) nil))
      (valsi-pi--fail-pending client (string-trim event) process)
      (valsi-pi--fail-session-lists client (string-trim event) process)
      (valsi-harness-emit
       client (list :type 'process-exit :status (process-status process)
                    :code (process-exit-status process) :event event
                    :deliberate (process-get process
                                             'valsi-pi-deliberate-stop)
                    :stderr (valsi-pi--stderr-string client process))))))

(defun valsi-pi--accept-session-list (client record)
  "Accept an audited session-list extension UI RECORD for CLIENT.
Return non-nil when RECORD belongs to the Valsi session bridge."
  (let ((key (plist-get record :widgetKey)))
    (when (and (equal (plist-get record :type) "extension_ui_request")
               (equal (plist-get record :method) "setWidget")
               (stringp key)
               (string-prefix-p "valsi-sessions:" key))
      (let* ((token (substring key (length "valsi-sessions:")))
             (entry (gethash token (valsi-pi-session-list-pending client))))
        (when entry
          (condition-case err
              (let* ((line (car (plist-get record :widgetLines)))
                     (payload
                      (json-parse-string
                       line :object-type 'plist :array-type 'list
                       :null-object nil :false-object :json-false)))
                (unless (and (= (or (plist-get payload :version) 0) 1)
                             (listp (plist-get payload :sessions)))
                  (error "Unsupported Valsi session-list payload"))
                (valsi-pi--finish-session-list
                 client token
                 (list :type "response" :command "valsi_list_sessions"
                       :success t
                       :data (list :sessions
                                   (plist-get payload :sessions)))
                 nil))
            (error
             (valsi-pi--finish-session-list client token nil err))))
        t))))

(defun valsi-pi--pending-callback (entry)
  "Return the callback stored in pending ENTRY.
Plain functions are accepted for compatibility with callers inspecting the
pending table in tests or while debugging."
  (if (functionp entry) entry (plist-get entry :callback)))

(defun valsi-pi--pending-process (entry)
  "Return the process stored in pending ENTRY, or nil for an unscoped entry."
  (and (listp entry) (plist-get entry :process)))

(defun valsi-pi--pending-command (entry)
  "Return the expected response command stored in pending ENTRY."
  (and (listp entry) (plist-get entry :command)))

(defun valsi-pi--accept-state (client record)
  "Validate pinned-Pi state RECORD and update CLIENT compatibility state.
Return nil when compatible, or the incompatibility message."
  (let* ((data (plist-get record :data))
         (missing
          (cl-remove-if (lambda (field) (and (listp data)
                                             (plist-member data field)))
                        valsi-pi--required-state-fields)))
    (if missing
        (let ((message
               (format "%s get_state missing required fields: %s"
                       valsi-pi-protocol-version
                       (mapconcat (lambda (field)
                                    (substring (symbol-name field) 1))
                                  missing ", "))))
          (setf (valsi-pi-protocol-compatible-p client) nil
                (valsi-pi-protocol-error client) message)
          (valsi-harness-emit
           client (list :type 'protocol-incompatible
                        :protocol valsi-pi-protocol-version
                        :record record :error message))
          message)
      (setf (valsi-pi-protocol-compatible-p client) t
            (valsi-pi-protocol-error client) nil
            (valsi-pi-session client) (plist-get data :sessionId))
      nil)))

(defun valsi-pi--call-callback (client callback response error)
  "Call CALLBACK with RESPONSE and ERROR without breaking CLIENT dispatch."
  (condition-case err
      (funcall callback response error)
    (error
     (valsi-harness-emit
      client (list :type 'callback-error
                   :error (error-message-string err))))))

(defun valsi-pi--fail-pending (client reason &optional process)
  "Fail CLIENT callbacks associated with PROCESS using REASON.
When PROCESS is nil, fail every pending callback."
  (let (callbacks)
    (maphash (lambda (id entry)
               (when (or (null process)
                         (null (valsi-pi--pending-process entry))
                         (eq process (valsi-pi--pending-process entry)))
                 (push (cons id (valsi-pi--pending-callback entry))
                       callbacks)))
             (valsi-pi-pending client))
    (dolist (item callbacks)
      (remhash (car item) (valsi-pi-pending client))
      (when (cdr item)
        (valsi-pi--call-callback
         client (cdr item) nil (list 'error reason))))))

(defun valsi-pi--stderr-string (client &optional process)
  "Return stderr captured for CLIENT or its particular PROCESS."
  (let ((buffer (if process
                    (process-get process 'valsi-pi-stderr-buffer)
                  (valsi-pi-stderr-buffer client))))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer (buffer-string))
      "")))

(provide 'valsi-pi)
;;; valsi-pi.el ends here

;;; valsi-server.el --- Strict stdio JSON-RPC server for AAP -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A small transport around `valsi-proto-json-request'.  Records are UTF-8 JSON
;; objects terminated by an ASCII LF.  Unicode line/paragraph separators are
;; ordinary characters, never frame boundaries.  The incremental consumer is
;; also used by tests and embedders; `valsi-server-stdio' is the headless entry
;; point used by the Pi extension.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'valsi-proto)

(cl-defstruct (valsi-server (:constructor valsi-server-create))
  "Incremental AAP JSON-RPC server state."
  (buffer "")
  send-function
  closed)

(defconst valsi-server-jsonrpc-version "2.0")

(declare-function valsi-plan-register "valsi-plan" ())
(declare-function valsi-instruction-register "valsi-instruction" ())
(declare-function valsi-promptfile-register "valsi-promptfile" ())
(declare-function valsi-memory-register "valsi-memory" ())
(declare-function valsi-changelog-register "valsi-changelog" ())
(declare-function valsi-decision-register "valsi-decision" ())
(declare-function valsi-overview-register "valsi-overview" ())

(defconst valsi-server--json-unavailable
  (concat "The AAP stdio server needs native JSON: "
          "Emacs 30, or Emacs 29 built with libjansson")
  "Message reported when `json-serialize' and `json-parse-string' are missing.")

(defun valsi-server--require-json ()
  "Signal a `user-error' unless Emacs has native JSON support.
Emacs 29 has `json-serialize' and `json-parse-string' only when built with
libjansson; Emacs 30 always has them."
  (unless (json-available-p)
    (user-error "%s" valsi-server--json-unavailable)))

(defun valsi-server--error (id code message &optional data)
  "Construct a JSON-RPC error for ID with CODE, MESSAGE, and optional DATA."
  (let ((error (list :code code :message message)))
    (when data
      (setq error (plist-put error :data data)))
    (list :jsonrpc valsi-server-jsonrpc-version
          :id (or id :null)
          :error error)))

(defun valsi-server--write-stdout (record)
  "Write RECORD to stdout as UTF-8 bytes and flush.
`json-serialize' returns unibyte UTF-8; `princ' would print each byte as a
raw-byte character in its internal two-byte form.  A unibyte string reaches
`send-string-to-terminal' unconverted, independent of the locale."
  (send-string-to-terminal
   (if (multibyte-string-p record)
       (encode-coding-string record 'utf-8-unix)
     record)))

(defun valsi-server--send (server value)
  "Encode VALUE as one strict-LF JSON record through SERVER.
The record is a unibyte UTF-8 string."
  (funcall (or (valsi-server-send-function server)
               #'valsi-server--write-stdout)
           (concat (json-serialize value :null-object :null
                                   :false-object :false)
                   "\n")))

(defun valsi-server--valid-id-p (id)
  "Return non-nil if ID is a valid JSON-RPC request id."
  (or (stringp id) (numberp id) (eq id :null)))

(defun valsi-server--dispatch (request)
  "Return the JSON-RPC response for parsed REQUEST, or nil for a notification."
  (let* ((has-id (plist-member request :id))
         (id (and has-id (plist-get request :id)))
         (version (plist-get request :jsonrpc))
         (method (plist-get request :method))
         (params (if (plist-member request :params)
                     (plist-get request :params)
                   nil)))
    (cond
     ((or (not (listp request))
          (not (equal version valsi-server-jsonrpc-version))
          (not (stringp method))
          (and has-id (not (valsi-server--valid-id-p id)))
          (and params (not (listp params))))
      (valsi-server--error (and (valsi-server--valid-id-p id) id)
                          -32600 "Invalid Request"))
     ((not (member (intern method) valsi-proto-methods))
      (and has-id (valsi-server--error id -32601 "Method not found" method)))
     (t
      (condition-case err
          ;; One budget for all declared-regexp matching in the request
          ;; (issue #80), across detection and every document it parses.
          (let ((result (valsi-registry-with-declarative-deadline
                          (valsi-proto-json-request method params))))
            (and has-id
                 (list :jsonrpc valsi-server-jsonrpc-version
                       :id id :result result)))
        ((valsi-proto-invalid-params wrong-type-argument)
         (and has-id
              (valsi-server--error id -32602 "Invalid params"
                                  (error-message-string err))))
        (error
         (and has-id
              (valsi-server--error id -32603 "Internal error"
                                  (error-message-string err)))))))))

(defun valsi-server--record (server record)
  "Parse and dispatch one JSON RECORD through SERVER."
  (if (or (string-empty-p record)
          ;; CRLF is deliberately not accepted by this strict-LF transport.
          (eq (aref record (1- (length record))) ?\r))
      (valsi-server--send server
                         (valsi-server--error nil -32700 "Parse error"))
    ;; Any failure to decode the record (including an invalid surrogate
    ;; escape, which `json-parse-string' does not report as
    ;; `json-parse-error') is a parse error; only later failures are -32600.
    (let ((request
           (condition-case err
               (json-parse-string record :object-type 'plist
                                  :array-type 'array
                                  :null-object :null
                                  :false-object :false)
             (error
              (valsi-server--send
               server (valsi-server--error nil -32700 "Parse error"
                                          (error-message-string err)))
              'valsi-server--unparsed))))
      (unless (eq request 'valsi-server--unparsed)
        (condition-case err
            (let ((response (valsi-server--dispatch request)))
              (when response (valsi-server--send server response)))
          (error
           (valsi-server--send
            server (valsi-server--error nil -32600 "Invalid Request"
                                       (error-message-string err)))))))))

(defun valsi-server-consume (server chunk)
  "Consume possibly partial strict-LF JSONL CHUNK for SERVER."
  (when (valsi-server-closed server)
    (error "AAP server is closed"))
  (valsi-server--require-json)
  (setf (valsi-server-buffer server)
        (concat (valsi-server-buffer server) chunk))
  (let ((start 0)
        (buffer (valsi-server-buffer server)))
    (while (string-match "\n" buffer start)
      ;; Dispatch can run arbitrary grammar regexps, so preserve this frame's
      ;; match data before it calls into the protocol.
      (let ((frame-end (match-beginning 0))
            (next (match-end 0)))
        (valsi-server--record server (substring buffer start frame-end))
        (setq start next)))
    (setf (valsi-server-buffer server) (substring buffer start))))

(defun valsi-server-eof (server)
  "Close SERVER, reporting an unterminated final record as a parse error."
  (unless (valsi-server-closed server)
    (unless (string-empty-p (valsi-server-buffer server))
      (valsi-server--require-json)
      (valsi-server--send
       server (valsi-server--error nil -32700
                                  "Parse error: record not terminated by LF")))
    (setf (valsi-server-buffer server) ""
          (valsi-server-closed server) t)))

(defun valsi-server-init ()
  "Register the bundled AAP grammars for a standalone server."
  (require 'valsi-registry)
  (valsi-registry-register-bundled))

(defun valsi-server--stdin-target ()
  "Return what this process's stdin refers to, or nil if unknown.
On Linux this is the `/proc' link target, such as \"pipe:[N]\",
\"socket:[N]\" or a file name."
  (and (file-directory-p "/proc/self/fd")
       (file-symlink-p (format "/proc/%d/fd/0" (emacs-pid)))))

(defun valsi-server--stdio-line-loop (server)
  "Feed SERVER from stdin one line at a time until EOF.
This is the fallback for stdin that cannot be reopened through `/proc', such
as the socketpair Node's `child_process.spawn' creates (opening a socket via
`/proc' fails with ENXIO).  Batch line input cannot tell an unterminated final
record from a terminated one, and ends a line at CR as well as LF, so this
path is less strict than the `/proc' reader."
  (condition-case nil
      (while t
        (valsi-server-consume server (concat (read-from-minibuffer "") "\n")))
    (end-of-file nil))
  (valsi-server-eof server))

(defun valsi-server--stdio-proc-reader (server stdin-path)
  "Feed SERVER from STDIN-PATH through an unbuffered shell reader until EOF.
The reader tags complete versus unterminated records, which preserves the
strict-LF EOF contract.  A reader failure is reported on stderr and ends
Emacs with a non-zero status instead of looking like EOF."
  (let* ((wrapper-buffer "")
         (errors (generate-new-buffer " *valsi-aap-stdin-errors*"))
         (shell (or (executable-find "sh")
                    (error "AAP stdio requires a POSIX shell")))
         (script
          (concat
           "exec 3< \"$1\" || exit 3\n"
           "line=\n"
           "while IFS= read -r line <&3; do\n"
           "  printf 'L%s\\n' \"$line\"\n"
           "  line=\n"
           "done\n"
           "if test -n \"$line\"; then\n"
           "  printf 'P%s\\n' \"$line\"\n"
           "else\n"
           "  printf 'E\\n'\n"
           "fi\n"))
         (reader
          (make-process
           :name "valsi-aap-stdin"
           :command (list shell "-c" script "valsi-aap-reader" stdin-path)
           :connection-type 'pipe
           :coding 'utf-8-unix
           :noquery t
           :stderr errors
           :filter
           (lambda (_process chunk)
             (setq wrapper-buffer (concat wrapper-buffer chunk))
             (let ((start 0))
               (while (string-match "\n" wrapper-buffer start)
                 (let ((end (match-beginning 0))
                       (next (match-end 0)))
                   (pcase (aref wrapper-buffer start)
                     (?L
                      (valsi-server-consume
                       server (concat (substring wrapper-buffer
                                                 (1+ start) end)
                                      "\n")))
                     (?P
                      (valsi-server-consume
                       server (substring wrapper-buffer (1+ start) end))
                      (valsi-server-eof server))
                     (?E (valsi-server-eof server)))
                   (setq start next)))
               (setq wrapper-buffer (substring wrapper-buffer start)))))))
    (while (process-live-p reader)
      (accept-process-output reader 0.1))
    (accept-process-output reader 0.1)
    (unless (zerop (process-exit-status reader))
      (message "valsi-server-stdio: cannot read stdin (%s): %s"
               stdin-path
               (string-trim (with-current-buffer errors (buffer-string))))
      (kill-emacs 2))
    (unless (valsi-server-closed server)
      (valsi-server-eof server))))

(defun valsi-server-stdio ()
  "Run the AAP reference server over stdin/stdout until EOF.
When stdin is a pipe or file, an unbuffered shell reader inherits it through
`/proc' and tags complete versus unterminated records.  This preserves the
strict-LF EOF contract that batch minibuffer input otherwise loses.  A socket
\(as created by Node's `child_process.spawn') cannot be reopened that way, so
it is read line by line instead.  Output is flushed after every response, so
callers never wait for process exit.
Without native JSON support, exit with status 3 and a message on stderr
instead of failing on the first request."
  (unless (json-available-p)
    (message "valsi-server-stdio: %s" valsi-server--json-unavailable)
    (kill-emacs 3))
  (valsi-server-init)
  (let ((server (valsi-server-create
                 :send-function #'valsi-server--write-stdout))
        (target (valsi-server--stdin-target)))
    (if (and target (not (string-prefix-p "socket:" target)))
        (valsi-server--stdio-proc-reader
         server (format "/proc/%d/fd/0" (emacs-pid)))
      (valsi-server--stdio-line-loop server))))

(provide 'valsi-server)
;;; valsi-server.el ends here

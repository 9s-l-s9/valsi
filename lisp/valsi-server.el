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

(defun valsi-server--error (id code message &optional data)
  "Construct a JSON-RPC error for ID with CODE, MESSAGE, and optional DATA."
  (let ((error (list :code code :message message)))
    (when data
      (setq error (plist-put error :data data)))
    (list :jsonrpc valsi-server-jsonrpc-version
          :id (or id :null)
          :error error)))

(defun valsi-server--send (server value)
  "Encode VALUE as one strict-LF JSON record through SERVER."
  (funcall (or (valsi-server-send-function server) #'princ)
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
          (let ((result (valsi-proto-json-request method params)))
            (and has-id
                 (list :jsonrpc valsi-server-jsonrpc-version
                       :id id :result result)))
        (wrong-type-argument
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
    (condition-case err
        (let* ((request
                (json-parse-string record :object-type 'plist
                                   :array-type 'array
                                   :null-object :null
                                   :false-object :false))
               (response (valsi-server--dispatch request)))
          (when response (valsi-server--send server response)))
      (json-parse-error
       (valsi-server--send
        server (valsi-server--error nil -32700 "Parse error"
                                   (error-message-string err))))
      (error
       (valsi-server--send
        server (valsi-server--error nil -32600 "Invalid Request"
                                   (error-message-string err)))))))

(defun valsi-server-consume (server chunk)
  "Consume possibly partial strict-LF JSONL CHUNK for SERVER."
  (when (valsi-server-closed server)
    (error "AAP server is closed"))
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
      (valsi-server--send
       server (valsi-server--error nil -32700
                                  "Parse error: record not terminated by LF")))
    (setf (valsi-server-buffer server) ""
          (valsi-server-closed server) t)))

(defun valsi-server-init ()
  "Register the bundled AAP grammars for a standalone server."
  (require 'valsi-registry)
  (require 'valsi-plan)
  (require 'valsi-instruction)
  (require 'valsi-promptfile)
  (require 'valsi-memory)
  (require 'valsi-changelog)
  (require 'valsi-decision)
  (require 'valsi-overview)
  (valsi-registry-init-generic)
  (valsi-plan-register)
  (valsi-instruction-register)
  (valsi-promptfile-register)
  (valsi-memory-register)
  (valsi-changelog-register)
  (valsi-decision-register)
  (valsi-overview-register))

(defun valsi-server-stdio ()
  "Run the AAP reference server over stdin/stdout until EOF.
An unbuffered shell reader inherits the process's stdin through `/proc' and
tags complete versus unterminated records.  This preserves the strict-LF EOF
contract that batch minibuffer input otherwise loses.  Output is flushed after
every response, so callers never wait for process exit."
  (valsi-server-init)
  (let* ((server
          (valsi-server-create
           :send-function
           (lambda (record)
             (princ record)
             (when (fboundp 'flush-standard-output)
               (flush-standard-output)))))
         (wrapper-buffer "")
         (stdin-path (format "/proc/%d/fd/0" (emacs-pid)))
         (shell (or (executable-find "sh")
                    (error "AAP stdio requires a POSIX shell")))
         (script
          (concat
           "exec 3< \"$1\"\n"
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
    (unless (valsi-server-closed server)
      (valsi-server-eof server))))

(provide 'valsi-server)
;;; valsi-server.el ends here

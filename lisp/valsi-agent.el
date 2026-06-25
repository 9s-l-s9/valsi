;;; valsi-agent.el --- Provider-neutral agent loop for Valsi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The brain tier of the agent core (tau's `tau_agent', research/03 Pattern 1):
;; a provider-neutral tool-use loop.  It is stateless -- the caller owns the
;; transcript -- and emits provider-neutral events on `valsi-agent-event-functions'
;; that views (streaming buffer, node-diff review) subscribe to.
;;
;; This tier depends only on the provider + tools tiers, nothing Valsi-specific:
;; the grammar modules call *into* it (Sprint 7), never the reverse.

;;; Code:

(require 'cl-lib)
(require 'valsi-agent-provider)
(require 'valsi-agent-tools)
(require 'valsi-agent-session)

;;;; Events

(defvar valsi-agent-event-functions nil
  "Abnormal hook run with each event plist during `valsi-agent-run'.
Event `:type' is one of `agent-start' `turn-start' `message' `tool-start'
`tool-end' `agent-end' `cancelled', plus any streaming events a provider adds.")

(defun valsi-agent--emit (event)
  "Run `valsi-agent-event-functions' with EVENT."
  (run-hook-with-args 'valsi-agent-event-functions event))

;;;; Cancellation token (mirrors tau's CancellationToken)

(defun valsi-agent-make-cancel ()
  "Return a fresh cancellation token."
  (cons 'valsi-cancel nil))

(defun valsi-agent-cancel (token)
  "Signal cancellation on TOKEN."
  (when token (setcdr token t)))

(defun valsi-agent-cancelled-p (token)
  "Return non-nil if TOKEN has been cancelled."
  (and token (cdr token)))

;;;; Scoping (control over delegation)

(cl-defmacro valsi-agent-scope ((&key tools files auto-approve dry-run) &rest body)
  "Run BODY scoped: TOOLS/FILES allow-lists, AUTO-APPROVE, DRY-RUN.
Binds the dynamic scope variables the tool layer consults per dispatch."
  (declare (indent 1))
  `(let ((valsi-agent-allowed-tools ,tools)
         (valsi-agent-allowed-files ,files)
         (valsi-agent-auto-approve ,auto-approve)
         (valsi-agent-dry-run ,dry-run))
     ,@body))

;;;; The loop

(defun valsi-agent--turn->message (turn)
  "Return the assistant message (role + content) for provider TURN."
  (list :role (or (plist-get turn :role) "assistant")
        :content (plist-get turn :content)))

(defun valsi-agent--resolve-tool (name tools)
  "Return the tool named NAME from TOOLS, falling back to the global registry."
  (or (cl-find name tools :key #'valsi-agent-tool-name :test #'equal)
      (valsi-agent-get-tool name)))

(cl-defun valsi-agent-run (&key provider system tools messages model
                               (max-tokens 4096) (max-turns 12) cancel session)
  "Drive the agent loop against PROVIDER; return the final MESSAGES list.

SYSTEM is the system prompt string.  TOOLS is a list of `valsi-agent-tool'.
MESSAGES is the caller-owned transcript (a list of message plists) that is
extended with assistant + tool-result messages.  MODEL/MAX-TOKENS shape the
request.  MAX-TURNS bounds the loop.  CANCEL is a token from
`valsi-agent-make-cancel'.  SESSION, if given, is a `valsi-agent-session' each
message is appended to."
  (valsi-agent--emit (list :type 'agent-start :model model))
  (let ((turn-n 0) (stop nil))
    (while (and (not stop) (< turn-n max-turns))
      (if (valsi-agent-cancelled-p cancel)
          (progn (valsi-agent--emit (list :type 'cancelled)) (setq stop 'cancelled))
        (cl-incf turn-n)
        (valsi-agent--emit (list :type 'turn-start :n turn-n))
        (let* ((request (list :system system
                              :messages messages
                              :tools (mapcar #'valsi-agent-tool-to-schema tools)
                              :model model :max-tokens max-tokens))
               (turn (valsi-agent-provider-stream
                      provider request #'valsi-agent--emit))
               (assistant (valsi-agent--turn->message turn)))
          (setq messages (append messages (list assistant)))
          (when session (valsi-agent-session-append session assistant))
          (let ((tool-uses (valsi-agent-turn-tool-uses turn)))
            (if (null tool-uses)
                (progn (valsi-agent--emit (list :type 'agent-end :reason 'stop))
                       (setq stop 'done))
              (let (result-blocks)
                (dolist (tu tool-uses)
                  (let* ((name (plist-get tu :name))
                         (id (plist-get tu :id))
                         (input (plist-get tu :input))
                         (tool (valsi-agent--resolve-tool name tools)))
                    (valsi-agent--emit (list :type 'tool-start :name name :input input))
                    (let ((res (if tool
                                   (valsi-agent-execute-tool tool input)
                                 (valsi-agent-tool-result-create
                                  :ok nil :error (format "unknown tool %s" name)
                                  :content (format "No such tool: %s" name)))))
                      (valsi-agent--emit (list :type 'tool-end :name name :result res))
                      (push (valsi-agent-tool-result-block
                             id (valsi-agent-tool-result-content res)
                             (not (valsi-agent-tool-result-ok res)))
                            result-blocks))))
                (let ((user-msg (valsi-agent-message "user" (nreverse result-blocks))))
                  (setq messages (append messages (list user-msg)))
                  (when session (valsi-agent-session-append session user-msg)))))))))
    (when (and (not stop) (>= turn-n max-turns))
      (valsi-agent--emit (list :type 'agent-end :reason 'max-turns)))
    messages))

;;;; Instruction-file loading (T608 -- minimal; grammar-aware version in Sprint 7)

(defun valsi-agent--nearest-instruction-files (dir names)
  "Return instruction files named NAMES from DIR up to the root, nearest last.
Concatenating in the returned order yields nearest-wins precedence."
  (let ((files nil) (dir (expand-file-name dir)))
    (while dir
      (dolist (n names)
        (let ((f (expand-file-name n dir)))
          (when (file-readable-p f) (push f files))))
      (let ((parent (file-name-directory (directory-file-name dir))))
        (setq dir (unless (equal parent dir) parent))))
    ;; We ascend DIR -> root pushing as we go, so the list ends up root-first /
    ;; nearest-last -- exactly nearest-wins concatenation order, no reverse.
    files))

(defun valsi-agent-load-instructions (&optional dir)
  "Assemble a system-context string from AGENTS.md/CLAUDE.md up from DIR.
Nearest-wins: files closer to DIR appear later (and thus override).  Minimal
Sprint-6 loader; swapped for the instruction grammar in Sprint 7 (T608)."
  (let* ((dir (or dir default-directory))
         (files (valsi-agent--nearest-instruction-files
                 dir '("AGENTS.md" "CLAUDE.md" ".valsi/instructions.md"))))
    (mapconcat
     (lambda (f)
       (format "# %s\n%s"
               (file-relative-name f dir)
               (with-temp-buffer (insert-file-contents f) (buffer-string))))
     files "\n\n")))

(provide 'valsi-agent)
;;; valsi-agent.el ends here

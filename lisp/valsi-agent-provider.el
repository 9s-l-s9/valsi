;;; valsi-agent-provider.el --- Provider transport for the Valsi agent core -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The provider transport tier of the agent core (tau's `tau_ai', research/03
;; Pattern 3).  A provider is a cl-struct dispatched by `cl-defgeneric'; the
;; brain (`valsi-agent') talks to it in a provider-neutral message vocabulary and
;; never knows which adapter is underneath.
;;
;; This tier depends on nothing Valsi-specific (no node model, no grammars) so it
;; stays reusable and never bleeds into the AAP surface.  The `mock' adapter here
;; makes the loop testable with no network; the real `anthropic-oauth' / `http'
;; adapters are added in T603.
;;
;; Message vocabulary (Anthropic-shaped, provider-neutral):
;;   message      (:role "user"|"assistant" :content [BLOCK ...])
;;   text block   (:type "text" :text STRING)
;;   tool_use     (:type "tool_use" :id ID :name NAME :input PLIST)
;;   tool_result  (:type "tool_result" :tool_use_id ID :content STRING
;;                 :is_error BOOL)
;;   turn         an assistant message plus (:stop-reason SYMBOL)

;;; Code:

(require 'cl-lib)

;;;; Provider base + generic transport

(cl-defstruct (valsi-agent-provider (:constructor valsi-agent-provider-create))
  "A model-provider transport.
NAME is a symbol; MODEL is the default model id used when a request omits one."
  (name 'generic)
  (model nil))

(cl-defgeneric valsi-agent-provider-request (provider request)
  "Send REQUEST to PROVIDER synchronously and return an assistant turn plist.
REQUEST is a plist with keys :system :messages :tools :model :max-tokens.  The
returned turn is (:role \"assistant\" :content [BLOCK ...] :stop-reason SYM).")

(cl-defgeneric valsi-agent-provider-stream (provider request handler)
  "Stream REQUEST to PROVIDER, calling HANDLER with event plists.
Return the final assistant turn.  The default method degrades to a single
`valsi-agent-provider-request' and emits one `message' event, so an adapter that
cannot stream still works.")

(cl-defmethod valsi-agent-provider-stream ((provider valsi-agent-provider)
                                          request handler)
  "Default non-streaming fallback: one request, one `message' event."
  (let ((turn (valsi-agent-provider-request provider request)))
    (when handler (funcall handler (list :type 'message :turn turn)))
    turn))

;;;; Message / block constructors + accessors (provider-neutral)

(defun valsi-agent-text-block (text)
  "Return a text content block carrying TEXT."
  (list :type "text" :text text))

(defun valsi-agent-tool-use-block (id name input)
  "Return a tool_use content block: call NAME (id ID) with INPUT plist."
  (list :type "tool_use" :id id :name name :input input))

(defun valsi-agent-tool-result-block (tool-use-id content &optional is-error)
  "Return a tool_result block for TOOL-USE-ID carrying CONTENT.
IS-ERROR marks a failed tool call so the model can react."
  (list :type "tool_result" :tool_use_id tool-use-id
        :content content :is_error (and is-error t)))

(defun valsi-agent-message (role blocks)
  "Return a message plist with ROLE and content vector BLOCKS (a list)."
  (list :role role :content (vconcat blocks)))

(cl-defun valsi-agent-turn (blocks &optional (stop-reason 'end_turn))
  "Return an assistant turn plist from content BLOCKS with STOP-REASON."
  (list :role "assistant" :content (vconcat blocks) :stop-reason stop-reason))

(defun valsi-agent-turn-blocks (turn)
  "Return TURN's content blocks as a list."
  (append (plist-get turn :content) nil))

(defun valsi-agent-turn-tool-uses (turn)
  "Return the tool_use blocks in TURN as a list."
  (cl-remove-if-not (lambda (b) (equal (plist-get b :type) "tool_use"))
                    (valsi-agent-turn-blocks turn)))

(defun valsi-agent-turn-text (turn)
  "Return the concatenated text of TURN's text blocks."
  (mapconcat (lambda (b) (or (plist-get b :text) ""))
             (cl-remove-if-not (lambda (b) (equal (plist-get b :type) "text"))
                               (valsi-agent-turn-blocks turn))
             ""))

(defun valsi-agent-message-text (message)
  "Return the concatenated text of MESSAGE's text blocks."
  (valsi-agent-turn-text message))

;;;; Mock adapter (deterministic tests -- research/03 Pattern 3, item 3)

(cl-defstruct (valsi-agent-mock-provider
               (:include valsi-agent-provider)
               (:constructor valsi-agent-mock-provider-create))
  "A deterministic provider for ERT.
SCRIPT is either a list of assistant turns returned in order, or a function of
the request returning a turn.  CALLS accumulates the requests seen (newest
first) for assertions."
  (script nil)
  (calls nil))

(cl-defmethod valsi-agent-provider-request ((provider valsi-agent-mock-provider)
                                           request)
  "Return the next scripted turn from PROVIDER, recording REQUEST."
  (push request (valsi-agent-mock-provider-calls provider))
  (let ((script (valsi-agent-mock-provider-script provider)))
    (if (functionp script)
        (funcall script request)
      (or (pop (valsi-agent-mock-provider-script provider))
          (valsi-agent-turn (list (valsi-agent-text-block "(mock: end)"))
                           'end_turn)))))

(provide 'valsi-agent-provider)
;;; valsi-agent-provider.el ends here

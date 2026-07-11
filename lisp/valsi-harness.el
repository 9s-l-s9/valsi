;;; valsi-harness.el --- Backend contract for Valsi agent runtimes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A deliberately small boundary between Valsi's artifact/UI layers and an
;; agent runtime.  Backends own execution and sessions; callers consume events
;; and issue correlated, asynchronous commands.

;;; Code:

(require 'cl-lib)

(defgroup valsi-harness nil
  "Agent-runtime integration for Valsi."
  :group 'valsi)

(defcustom valsi-harness-backend 'pi
  "Backend used for interactive Valsi dispatch.
Pi is the sole supported production value.  The legacy `native' value is not
offered through Customize; it remains available to tests and as an explicitly
enabled emergency fallback."
  :type '(const :tag "Pi (production)" pi)
  :group 'valsi-harness)

(defcustom valsi-harness-enable-native-fallback nil
  "Permit the legacy native harness for an emergency or offline test.
This does not configure a provider, expose native credentials, or make native
sessions part of the production workflow.  Leave nil for normal use."
  :type 'boolean
  :group 'valsi-harness)

(cl-defstruct (valsi-harness (:constructor nil))
  "Base state shared by harness implementations."
  (event-functions nil))

(cl-defgeneric valsi-harness-start (harness)
  "Start HARNESS and return it.")

(cl-defgeneric valsi-harness-stop (harness)
  "Stop HARNESS deliberately.")

(cl-defgeneric valsi-harness-request (harness command callback)
  "Send COMMAND through HARNESS.
CALLBACK is called as (CALLBACK RESPONSE ERROR), exactly once.  Return the
request id immediately.")

(cl-defgeneric valsi-harness-notify (harness message)
  "Send uncorrelated protocol MESSAGE through HARNESS unchanged.")

(cl-defgeneric valsi-harness-live-p (harness)
  "Return non-nil when HARNESS can accept commands.")

(cl-defgeneric valsi-harness-session-id (harness)
  "Return HARNESS's current session identity, or nil.")

(defun valsi-harness-emit (harness event)
  "Deliver EVENT to HARNESS listeners."
  (dolist (fn (valsi-harness-event-functions harness))
    (condition-case err
        (funcall fn event)
      (error (message "Valsi harness event listener failed: %s"
                      (error-message-string err))))))

(defun valsi-harness-prompt (harness message &optional callback)
  "Send MESSAGE as a new prompt through HARNESS."
  (valsi-harness-request
   harness (list :type "prompt" :message message) callback))

(defun valsi-harness-steer (harness message &optional callback)
  "Queue steering MESSAGE through HARNESS."
  (valsi-harness-request
   harness (list :type "steer" :message message) callback))

(defun valsi-harness-follow-up (harness message &optional callback)
  "Queue follow-up MESSAGE through HARNESS."
  (valsi-harness-request
   harness (list :type "follow_up" :message message) callback))

(defun valsi-harness-abort (harness &optional callback)
  "Abort the current operation in HARNESS, then invoke CALLBACK."
  (valsi-harness-request harness (list :type "abort") callback))

(defun valsi-harness-state (harness &optional callback)
  "Request current HARNESS state, then invoke CALLBACK."
  (valsi-harness-request harness (list :type "get_state") callback))

(defun valsi-harness-messages (harness &optional callback)
  "Request HARNESS's authoritative current-session messages.
CALLBACK receives the backend's correlated response and error.  Production
backends must obtain these from their own session owner; callers must not scan
or mirror a backend's private session store."
  (valsi-harness-request harness (list :type "get_messages") callback))

(defun valsi-harness-set-model (harness provider model-id &optional callback)
  "Select PROVIDER and MODEL-ID in HARNESS."
  (valsi-harness-request
   harness (list :type "set_model" :provider provider :modelId model-id)
   callback))

(provide 'valsi-harness)
;;; valsi-harness.el ends here

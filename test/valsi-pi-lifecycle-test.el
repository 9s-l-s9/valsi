;;; valsi-pi-lifecycle-test.el --- RPC resource lifetime tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Exercise the retained RPC test support without launching a coding agent.

;;; Code:

(require 'ert)
(require 'valsi-pi)

(defmacro valsi-pi-lifecycle--with-client (&rest body)
  "Run BODY with a temporary CLIENT and pipe processes in place of Pi."
  (declare (indent 0))
  `(let* ((directory (make-temp-file "valsi-pi-lifecycle-" t))
          (temporary-file-directory directory)
          (valsi-pi--clients nil)
          (client (valsi-pi-create :directory directory)))
     (skip-unless (json-available-p))
     (unwind-protect
         (cl-letf (((symbol-function 'make-process)
                    (lambda (&rest options)
                      (make-pipe-process
                       :name "valsi-pi-lifecycle" :noquery t
                       :sentinel (plist-get options :sentinel)))))
           ,@body)
       (valsi-harness-stop client)
       (delete-directory directory t))))

(defun valsi-pi-lifecycle--policy (client)
  "Read CLIENT's current policy as a plist."
  (with-temp-buffer
    (insert-file-contents (valsi-pi-policy-file client))
    (json-parse-buffer :object-type 'plist :array-type 'list)))

(ert-deftest valsi-pi-lifecycle-release-revokes-authority ()
  "Only the active owner can release, and release installs deny-all (#101)."
  (valsi-pi-lifecycle--with-client
    (valsi-pi-set-policy client "task" '("write") '("secret.md"))
    (valsi-pi-claim-policy client "task")
    (should-not (valsi-pi-release-policy client "other"))
    (should (equal '("write") (plist-get (valsi-pi-lifecycle--policy client) :tools)))
    (should (valsi-pi-release-policy client "task"))
    (should-not (valsi-pi-policy-owner client))
    (let ((policy (valsi-pi-lifecycle--policy client)))
      (should-not (plist-get policy :tools))
      (should-not (plist-get policy :files))
      (should (eq t (plist-get policy :dryRun))))))

(ert-deftest valsi-pi-lifecycle-start-restart-and-crash-clean-resources ()
  "New processes start denied; old files and stderr buffers are released."
  (valsi-pi-lifecycle--with-client
    (valsi-pi-set-policy client "stale" '("write") '("secret.md"))
    (valsi-pi-claim-policy client "stale")
    (let ((stale (valsi-pi-policy-file client)))
      (valsi-harness-start client)
      (should-not (file-exists-p stale)))
    (should-not (valsi-pi-policy-owner client))
    (should-not (plist-get (valsi-pi-lifecycle--policy client) :tools))
    (let ((old-process (valsi-pi-process client))
          (old-file (valsi-pi-policy-file client))
          (old-buffer (valsi-pi-stderr-buffer client)))
      (valsi-pi-set-policy client "task" '("write") '("secret.md"))
      (valsi-pi-restart client)
      (should-not (file-exists-p old-file))
      (should-not (buffer-live-p old-buffer))
      (should-not (plist-get (valsi-pi-lifecycle--policy client) :tools))
      (valsi-pi-claim-policy client "new")
      ;; A late old-generation sentinel must not revoke the new owner.
      (valsi-pi--process-sentinel old-process "old exit")
      (should (equal "new" (valsi-pi-policy-owner client)))
      (should (file-exists-p (valsi-pi-policy-file client))))
    (let ((path (valsi-pi-policy-file client))
          (stderr (valsi-pi-stderr-buffer client)))
      (with-current-buffer stderr (insert "crash detail"))
      (delete-process (valsi-pi-process client))
      (should-not (file-exists-p path))
      (should-not (buffer-live-p stderr))
      (should-not (valsi-pi-policy-owner client))
      (should (equal "crash detail" (valsi-pi--stderr-string client)))
      (should-not valsi-pi--clients))))

(ert-deftest valsi-pi-lifecycle-start-failure-and-shutdown-release-resources ()
  "Failed spawning and Emacs exit also clean up the tracked clients."
  (valsi-pi-lifecycle--with-client
    (let ((before (buffer-list)))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (error "cannot spawn"))))
        (should-error (valsi-harness-start client)))
      (should-not (seq-difference (buffer-list) before))
      (should-not (valsi-pi-policy-file client))
      (should-not valsi-pi--clients))
    (valsi-harness-start client)
    (let ((path (valsi-pi-policy-file client))
          (stderr (valsi-pi-stderr-buffer client)))
      (valsi-pi--shutdown)
      (should-not (valsi-harness-live-p client))
      (should-not (file-exists-p path))
      (should-not (buffer-live-p stderr))
      (should-not valsi-pi--clients))))

(ert-deftest valsi-pi-lifecycle-timeout-finishes-once-and-ignores-late-response ()
  "The scheduled request timeout releases its closure and fires only once."
  (valsi-pi-lifecycle--with-client
    (valsi-harness-start client)
    (let (scheduled calls)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (delay repeat function &rest args)
                   (should (= delay valsi-pi-request-timeout))
                   (should-not repeat)
                   (setq scheduled (cons function args))
                   nil)))
        (let ((id (valsi-harness-request
                   client '(:type "get_messages")
                   (lambda (response error) (push (list response error) calls)))))
          (apply (car scheduled) (cdr scheduled))
          (should (= 0 (hash-table-count (valsi-pi-pending client))))
          (should (string-match-p "timed out" (cadr (cadar calls))))
          (valsi-pi--consume
           client (format "{\"type\":\"response\",\"id\":\"%s\",\"command\":\"get_messages\",\"success\":true}\n" id))
          (apply (car scheduled) (cdr scheduled))
          (should (= 1 (length calls))))))))

(ert-deftest valsi-pi-lifecycle-response-stop-and-send-failure-cancel-timers ()
  "Every request settlement removes its timeout, including write failures."
  (valsi-pi-lifecycle--with-client
    (valsi-harness-start client)
    (let ((id (valsi-harness-request client '(:type "get_messages") nil)))
      (let ((timer (plist-get (gethash id (valsi-pi-pending client)) :timer)))
        (should (memq timer timer-list))
        (valsi-pi--consume
         client (format "{\"type\":\"response\",\"id\":\"%s\",\"command\":\"get_messages\",\"success\":true}\n" id))
        (should-not (memq timer timer-list))))
    (let* ((id (valsi-harness-request client '(:type "get_messages") nil))
           (timer (plist-get (gethash id (valsi-pi-pending client)) :timer)))
      (valsi-harness-stop client)
      (should-not (memq timer timer-list)))
    (valsi-harness-start client)
    (let ((before (copy-sequence timer-list)) calls)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (&rest _) (error "cannot write"))))
        (should-error (valsi-harness-request client '(:type "get_messages")
                                             (lambda (&rest _) (push t calls)))))
      (should (= 1 (length calls)))
      (should-not (seq-difference timer-list before))
      (should (= 0 (hash-table-count (valsi-pi-pending client)))))))

(provide 'valsi-pi-lifecycle-test)
;;; valsi-pi-lifecycle-test.el ends here

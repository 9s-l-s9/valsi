;;; valsi-plan-review-test.el --- ERT tests for plan review + plan agent -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unit tests for the node-diff review workflow (update / toggle /
;; accept-all / reject-all / apply) and for the plan-agent dispatch logic
;; with the terminal-agent layer mocked out via `cl-letf'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-plan-review)
(require 'valsi-plan-agent)

(defconst valsi-plan-review-test--old
  (concat "# Plan\n\n"
          "- [ ] 1.1 Write the parser\n"
          "- [ ] 1.2 Write the linter\n"
          "- [x] 1.3 Ship it\n")
  "The plan content before an agent edit.")

(defconst valsi-plan-review-test--new
  (concat "# Plan\n\n"
          "- [x] 1.1 Write the parser\n"
          "- [x] 1.3 Ship it\n"
          "- [ ] 1.4 Document it\n")
  "The agent's proposed plan: 1.1 modified, 1.2 removed, 1.4 added.")

(defmacro valsi-plan-review-test--with-review (&rest body)
  "Open a review of the fixture edit and run BODY in the review buffer."
  `(with-temp-buffer
     (insert valsi-plan-review-test--old)
     (let ((target (current-buffer)))
       (cl-letf (((symbol-function 'switch-to-buffer) #'ignore)
                 ((symbol-function 'quit-window) #'ignore))
         (valsi-plan-review-update valsi-plan-review-test--new)
         (unwind-protect
             (with-current-buffer "*valsi-plan-review*"
               (ignore target)
               ,@body)
           (kill-buffer "*valsi-plan-review*"))))))

(ert-deftest valsi-test-plan-review-diff-kinds ()
  "The node diff reports modified, removed, and added tasks by id."
  (let ((changes (valsi-plan-diff valsi-plan-review-test--old
                                 valsi-plan-review-test--new)))
    (should (= 3 (length changes)))
    (let ((by-id (lambda (id) (cl-find id changes
                                       :key (lambda (c) (plist-get c :id))
                                       :test #'equal))))
      (should (eq 'modified (plist-get (funcall by-id "1.1") :kind)))
      (should (eq 'removed (plist-get (funcall by-id "1.2") :kind)))
      (should (eq 'added (plist-get (funcall by-id "1.4") :kind))))))

(ert-deftest valsi-test-plan-review-reject-all-byte-identical ()
  "Applying with every change rejected restores the file byte-identically."
  (valsi-plan-review-test--with-review
   (valsi-plan-review-reject-all)
   (should (cl-notany #'cdr valsi-plan-review--changes))
   (let ((target valsi-plan-review--target))
     (valsi-plan-review-apply)
     (should (equal valsi-plan-review-test--old
                    (with-current-buffer target (buffer-string)))))))

(ert-deftest valsi-test-plan-review-accept-all-yields-agent-version ()
  "Accept-all applies every change: edit, removal, and addition."
  (valsi-plan-review-test--with-review
   (valsi-plan-review-reject-all)
   (valsi-plan-review-accept-all)
   (should (cl-every #'cdr valsi-plan-review--changes))
   (let ((target valsi-plan-review--target))
     (valsi-plan-review-apply)
     (with-current-buffer target
       (should (string-match-p "- \\[x\\] 1\\.1" (buffer-string)))
       (should-not (string-match-p "1\\.2" (buffer-string)))
       (should (string-match-p "- \\[ \\] 1\\.4 Document it" (buffer-string)))))))

(ert-deftest valsi-test-plan-review-toggle-partial-apply ()
  "Toggling one row off applies only the remaining accepted changes."
  (valsi-plan-review-test--with-review
   ;; Reject the first listed change (the modification of 1.1) only.
   (goto-char (point-min))
   (forward-line 2)
   (valsi-plan-review-toggle)
   (let ((target valsi-plan-review--target))
     (valsi-plan-review-apply)
     (with-current-buffer target
       (should (string-match-p "- \\[ \\] 1\\.1" (buffer-string)))
       (should-not (string-match-p "1\\.2" (buffer-string)))
       (should (string-match-p "1\\.4" (buffer-string)))))))

(ert-deftest valsi-test-plan-review-no-changes-no-buffer ()
  "An identical proposal opens no review buffer."
  (with-temp-buffer
    (insert valsi-plan-review-test--old)
    (valsi-plan-review-update valsi-plan-review-test--old)
    (should-not (get-buffer "*valsi-plan-review*"))))

;;;; Plan agent (terminal layer mocked)

(defconst valsi-plan-agent-test--plan
  (concat "## Sprint 1\n\n"
          "- [ ] 1.1 Build parser (deps: none) `lisp/valsi-parse.el`\n"
          "  - Step one\n"
          "  - _Verify: run `make check`_\n")
  "A plan fixture with one task carrying steps and verify metadata.")

(ert-deftest valsi-test-plan-agent-bundle-and-prompt ()
  "The context bundle and rendered prompt carry id, group, and steps."
  (let* ((root (valsi-plan-parse valsi-plan-agent-test--plan))
         (task (car (valsi-node-of-type root 'task)))
         (bundle (valsi-plan-context-bundle root task))
         (prompt (valsi-plan-bundle->prompt bundle)))
    (should (equal "1.1" (plist-get bundle :id)))
    (should (equal "Sprint 1" (plist-get bundle :group)))
    (should (string-match-p "Implement task 1.1" prompt))
    (should (string-match-p "Group: Sprint 1" prompt))
    (should (string-match-p "  - Step one" prompt))))

(ert-deftest valsi-test-plan-agent-dispatch-pastes-without-submit ()
  "Dispatch pastes the task prompt into the mocked agent terminal."
  (let (inserted)
    (cl-letf (((symbol-function 'valsi-terminal-agent-insert)
               (lambda (text &optional _name) (setq inserted text)))
              ((symbol-function 'message) #'ignore))
      (with-temp-buffer
        (insert valsi-plan-agent-test--plan)
        (goto-char (point-min))
        (search-forward "1.1")
        (valsi-plan-dispatch-task)))
    (should inserted)
    (should (string-match-p "Implement task 1.1" inserted))
    (should (string-match-p "context hints" inserted))))

(ert-deftest valsi-test-plan-agent-dispatch-errors-off-task ()
  "Dispatch on a non-task line signals a user error, touching no agent."
  (cl-letf (((symbol-function 'valsi-terminal-agent-insert)
             (lambda (&rest _) (error "Must not be called"))))
    (with-temp-buffer
      (insert valsi-plan-agent-test--plan)
      (goto-char (point-min))               ; the heading line
      (should-error (valsi-plan-dispatch-task) :type 'user-error))))

(ert-deftest valsi-test-plan-agent-distill-done ()
  "Distill-done emits modified diffs only for not-yet-done listed ids."
  (let ((changes (valsi-plan-distill-done valsi-plan-review-test--old
                                         '("1.1" "1.3"))))
    (should (= 1 (length changes)))
    (let ((ch (car changes)))
      (should (equal "1.1" (plist-get ch :id)))
      (should (eq 'modified (plist-get ch :kind)))
      (should (string-match-p "\\[x\\]" (plist-get ch :new))))))

(provide 'valsi-plan-review-test)
;;; valsi-plan-review-test.el ends here

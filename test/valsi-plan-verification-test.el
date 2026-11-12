;;; valsi-plan-verification-test.el --- Verification regressions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Check document-derived commands without executing them, then exercise the
;; real compilation sentinel with harmless shell exit commands.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi)
(require 'valsi-plan-agent)

(defmacro valsi-plan-verification-test--with-runner (&rest body)
  "Run BODY with a recording compilation runner and editable command prompt."
  (declare (indent 0) (debug t))
  `(let (runs prompts buffers
              (answer (lambda (command) command)))
     (unwind-protect
         (cl-letf (((symbol-function 'read-shell-command)
                    (lambda (prompt command &rest _)
                      (push (list prompt command default-directory) prompts)
                      (funcall answer command)))
                   ((symbol-function 'process-buffer) #'identity)
                   ((symbol-function 'compile)
                    (lambda (command &rest _)
                      (let ((buffer (generate-new-buffer
                                     (funcall compilation-buffer-name-function
                                              "compilation"))))
                        (push buffer buffers)
                        (push (list command default-directory buffer) runs)
                        (with-current-buffer buffer
                          (compilation-mode)
                          (run-hook-with-args 'compilation-start-hook buffer))
                        buffer))))
           ,@body)
       (mapc #'kill-buffer buffers))))

(defun valsi-plan-verification-test--finish (buffer code &optional status)
  "Finish a stubbed run in BUFFER with CODE and process STATUS."
  (cl-letf (((symbol-function 'process-status) (lambda (_) (or status 'exit)))
            ((symbol-function 'process-exit-status) (lambda (_) code)))
    (valsi-plan--finish-verification buffer "finished\n")))

(ert-deftest valsi-plan-verification-reviews-command-and-directory ()
  "Both actions prompt before running an edited command from the project root."
  (dolist (action '(valsi-plan-run-verification
                    valsi-plan-complete-with-verification))
    (valsi-plan-verification-test--with-runner
      (with-temp-buffer
        (insert "- [ ] T001 Check\n  **Verify:** run `make test` then `make all`\n")
        (goto-char (point-min))
        (setq buffer-file-name "/tmp/project/specs/001/tasks.md"
              default-directory "/tmp/project/specs/001/"
              valsi-project-root "/tmp/project/")
        (setq answer (lambda (command)
                       (should-not runs)
                       (should (equal command "make test"))
                       "make check"))
        (funcall action)
        (should (equal (caar runs) "make check"))
        (should (equal (cadar runs) "/tmp/project/"))
        (should (string-match-p "/tmp/project/" (caar prompts)))
        (should (string-prefix-p "- [ ]" (buffer-string)))))))

(ert-deftest valsi-plan-verification-outside-project ()
  "A plan without a project uses its file directory, or its default directory."
  (dolist (file '("/tmp/spec/tasks.md" nil))
    (valsi-plan-verification-test--with-runner
      (with-temp-buffer
        (insert "- [ ] Check\n  **Verify:** `true`\n")
        (goto-char (point-min))
        (setq buffer-file-name file default-directory "/tmp/")
        (cl-letf (((symbol-function 'valsi-project-current-root) #'ignore))
          (valsi-plan-run-verification))
        (should (equal (cadar runs) (if file "/tmp/spec/" "/tmp/")))))))

(ert-deftest valsi-plan-verification-requires-own-command ()
  "Missing metadata and a parent's or child's Verify never run a command."
  (dolist (action '(valsi-plan-run-verification
                    valsi-plan-complete-with-verification))
    (dolist (content '("- [ ] T001 No verification\n"
                       "- [ ] T001 Parent\n  **Verify:** `parent`\n  - [ ] T001.1 Child\n"
                       "- [ ] T001 Parent\n  - [ ] T001.1 Child\n    **Verify:** `child`\n"))
      (valsi-plan-verification-test--with-runner
        (with-temp-buffer
          (insert content)
          (goto-char (point-min))
          (when (string-match-p "`parent`" content) (forward-line 2))
          (funcall action)
          (should-not runs)
          (should-not prompts))))))

(ert-deftest valsi-plan-verification-cancel-or-empty-runs-nothing ()
  "Cancelling the prompt or accepting an empty command cannot launch a shell."
  (dolist (action '(valsi-plan-run-verification
                    valsi-plan-complete-with-verification))
    (dolist (cancel '(nil t))
      (valsi-plan-verification-test--with-runner
        (with-temp-buffer
          (insert "- [ ] Check\n  **Verify:** `make test`\n")
          (goto-char (point-min))
          (setq answer (lambda (_) (if cancel (signal 'quit nil) "  ")))
          (if cancel
              (should (eq 'cancelled
                          (condition-case nil (funcall action)
                            (quit 'cancelled))))
            (should-error (funcall action) :type 'user-error))
          (should-not runs))))))

(ert-deftest valsi-plan-verification-completes-original-task ()
  "Success follows the task across unrelated edits and preserves point/narrowing."
  (valsi-plan-verification-test--with-runner
    (with-temp-buffer
      (insert "# Plan\n- [ ] T001 Check\n  **Verify:** `make test`\n- [ ] T002 Other\n")
      (goto-char (point-min))
      (forward-line 1)
      (narrow-to-region (point) (point-max))
      (let ((output (valsi-plan-complete-with-verification)))
        (should (string-prefix-p "- [ ]" (buffer-string)))
        (widen)
        (goto-char (point-min))
        (insert "Introduction\n")
        (goto-char (point-max))
        (forward-line -1)
        (narrow-to-region (point) (point-max))
        (let ((position (point)) (minimum (point-min)))
          (valsi-plan-verification-test--finish output 0)
          (should (= position (point)))
          (should (= minimum (point-min)))))
      (widen)
      (should (string-match-p "- \\[x\\] T001" (buffer-string)))
      (should (string-match-p "- \\[ \\] T002" (buffer-string))))))

(ert-deftest valsi-plan-verification-rejects-changed-task ()
  "Changes to the task, its metadata or children invalidate completion."
  (dolist (old '("T001" "make test" "Child"))
    (valsi-plan-verification-test--with-runner
      (with-temp-buffer
        (insert "- [ ] T001 Parent\n  **Verify:** `make test`\n  - [ ] T001.1 Child\n")
        (goto-char (point-min))
        (let ((output (valsi-plan-complete-with-verification)))
          (search-forward old)
          (replace-match "changed")
          (let ((before (buffer-string)))
            (valsi-plan-verification-test--finish output 0)
            (should (equal before (buffer-string)))))))))

(ert-deftest valsi-plan-verification-failure-and-signal-keep-task ()
  "A nonzero exit or signal keeps the checkbox open without a blocking prompt."
  (dolist (result '((exit 7) (signal 0)))
    (valsi-plan-verification-test--with-runner
      (with-temp-buffer
        (insert "- [ ] Check\n  **Verify:** `false`\n")
        (goto-char (point-min))
        (let ((output (valsi-plan-complete-with-verification))
              (before (buffer-string)))
          (valsi-plan-verification-test--finish output (cadr result) (car result))
          (should (equal before (buffer-string)))
          (should-not (buffer-local-value 'valsi-plan--verification output)))))))

(ert-deftest valsi-plan-verification-independent-runs-and-one-shot-completion ()
  "Concurrent runs keep their own source; recompile cannot complete again."
  (valsi-plan-verification-test--with-runner
    (with-temp-buffer
      (insert "- [ ] T001 One\n  **Verify:** `one`\n- [ ] T002 Two\n  **Verify:** `two`\n")
      (goto-char (point-min))
      (let ((one (valsi-plan-complete-with-verification)))
        (forward-line 2)
        (let ((two (valsi-plan-complete-with-verification)))
          (should-not (eq one two))
          (valsi-plan-verification-test--finish two 0)
          (valsi-plan-verification-test--finish one 1)
          (should (string-match-p "- \\[ \\] T001" (buffer-string)))
          (should (string-match-p "- \\[x\\] T002" (buffer-string)))
          (let ((before (buffer-string)))
            (valsi-plan-verification-test--finish one 0)
            (should (equal before (buffer-string)))))))))

(ert-deftest valsi-plan-verification-closed-source-and-output ()
  "Closing either buffer releases markers without modifying another buffer."
  (valsi-plan-verification-test--with-runner
    (let (output marker)
      (with-temp-buffer
        (insert "- [ ] Check\n  **Verify:** `true`\n")
        (goto-char (point-min))
        (setq output (valsi-plan-complete-with-verification)
              marker (nth 1 (buffer-local-value 'valsi-plan--verification output))))
      (valsi-plan-verification-test--finish output 0)
      (should-not (marker-buffer marker)))
    (with-temp-buffer
      (insert "- [ ] Check\n  **Verify:** `true`\n")
      (goto-char (point-min))
      (let* ((output (valsi-plan-complete-with-verification))
             (marker (nth 1 (buffer-local-value 'valsi-plan--verification output))))
        (kill-buffer output)
        (should-not (marker-buffer marker))))))

(ert-deftest valsi-plan-verification-respects-read-only-and-browse ()
  "Completion can edit Browse but respects buffers that were already read-only."
  (dolist (read-only '(nil t))
    (valsi-plan-verification-test--with-runner
      (with-temp-buffer
        (insert "- [ ] Check\n  **Verify:** `true`\n")
        (goto-char (point-min))
        (setq buffer-read-only t
              valsi--interaction-state 'browse
              valsi--original-read-only read-only)
        (valsi-plan-verification-test--finish
         (valsi-plan-complete-with-verification) 0)
        (should buffer-read-only)
        (should (string-prefix-p (if read-only "- [ ]" "- [x]")
                                 (buffer-string)))))))

(ert-deftest valsi-plan-verification-real-compilation ()
  "The real compilation sentinel completes on exit zero, never on exit seven."
  (dolist (code '(0 7))
    (with-temp-buffer
      (insert (format "- [ ] Check\n  **Verify:** `exit %d`\n" code))
      (goto-char (point-min))
      (let (output)
        (unwind-protect
            (cl-letf (((symbol-function 'read-shell-command)
                       (lambda (_ command &rest _) command)))
              (setq output (valsi-plan-complete-with-verification))
              (let ((deadline (+ (float-time) 5)))
                (while (and (buffer-local-value 'valsi-plan--verification output)
                            (< (float-time) deadline))
                  (accept-process-output nil 0.05)))
              (should-not (buffer-local-value 'valsi-plan--verification output))
              (should (string-prefix-p (if (zerop code) "- [x]" "- [ ]")
                                       (buffer-string))))
          (when (buffer-live-p output) (kill-buffer output)))))))

(provide 'valsi-plan-verification-test)
;;; valsi-plan-verification-test.el ends here

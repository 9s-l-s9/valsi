;;; valsi-terminal-agent-test.el --- Terminal agent naming and lookup tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Regression tests for named terminal agents.  Pipe processes stand in for
;; the Eat terminal and the agent CLI.

;;; Code:

(require 'ert)
(require 'valsi-terminal-agent)

(defmacro valsi-terminal-agent-test--with-root (&rest body)
  "Run BODY with ROOT bound to a temporary project and fake terminals."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory
                 (file-truename (make-temp-file "valsi-agent-test-" t))))
          (default-directory root)
          (before (buffer-list))
          (valsi-project-root nil)
          (valsi-project-file nil)
          (valsi-project--loaded t)
          (valsi-project--roots nil)
          (valsi-project-change-hook nil)
          (valsi-terminal-agent-change-hook nil)
          (valsi-terminal-agent--instances (make-hash-table :test #'equal)))
     (unwind-protect
         (cl-letf (((symbol-function 'valsi-terminal-agent--eat) #'ignore)
                   ((symbol-function 'valsi-terminal-agent--ensure-program)
                    (lambda (program _backend) program))
                   ((symbol-function 'project-current) #'ignore)
                   ((symbol-function 'eat-make)
                    (lambda (name &rest _)
                      (let ((buffer (generate-new-buffer name)))
                        (make-pipe-process :name name :buffer buffer :noquery t)
                        buffer))))
           ,@body)
       (dolist (buffer (seq-difference (buffer-list) before))
         (when (buffer-live-p buffer)
           (when-let* ((process (get-buffer-process buffer)))
             (delete-process process))
           (let ((kill-buffer-query-functions nil))
             (kill-buffer buffer))))
       (delete-directory root t))))

(ert-deftest valsi-terminal-agent-test-get-canonicalizes-root ()
  "Lookups without a trailing slash or through a symlink find the agent (#43)."
  (valsi-terminal-agent-test--with-root
    (let ((alias (concat (directory-file-name root) "-alias")))
      (unwind-protect
          (progn
            (make-symbolic-link (directory-file-name root) alias)
            (save-window-excursion (valsi-agent "primary" 'pi))
            (should (valsi-terminal-agent-get root "primary"))
            (should (valsi-terminal-agent-get (directory-file-name root) "primary"))
            (should (valsi-terminal-agent-get alias "primary"))
            (should (valsi-terminal-agent-get (file-name-as-directory alias) "primary")))
        (when (file-symlink-p alias) (delete-file alias))))))

(ert-deftest valsi-terminal-agent-test-target-respects-explicit-name ()
  "An explicitly named target that is not running is an error (#40)."
  (valsi-terminal-agent-test--with-root
    (let ((primary (save-window-excursion (valsi-agent "primary" 'pi))))
      (should-error (valsi-terminal-agent--target "docs") :type 'user-error)
      (should (eq primary (valsi-terminal-agent--target)))
      (should (eq primary (valsi-terminal-agent--target "primary")))
      (let ((docs (save-window-excursion (valsi-agent-new "docs" 'pi))))
        (should (eq docs (valsi-terminal-agent--target "docs"))))
      (should (= 2 (length (valsi-terminal-agent-list root)))))))

(ert-deftest valsi-terminal-agent-test-rejects-blank-names ()
  "Empty or whitespace-only agent names are rejected, others trimmed (#41)."
  (valsi-terminal-agent-test--with-root
    (should-error (valsi-agent-new "" 'pi) :type 'user-error)
    (should-error (valsi-agent-new "   " 'pi) :type 'user-error)
    (should-error (valsi-agent " \t" 'pi) :type 'user-error)
    (should-not (valsi-terminal-agent-list root))
    (let ((docs (save-window-excursion (valsi-agent-new " docs " 'pi))))
      (should (equal "docs" (valsi-terminal-agent-instance-name docs))))
    (save-window-excursion (valsi-agent "primary" 'pi))
    ;; RET at the New prompt neither proposes the running primary nor
    ;; accepts an empty name.
    (let (default)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt _collection &optional _pred _req _init _hist def &rest _)
                   (setq default def)
                   (or def ""))))
        (should-error (valsi-terminal-agent--read-name root "New agent name: " t)
                      :type 'user-error)
        (should-not default)))))

(ert-deftest valsi-terminal-agent-test-header-escapes-percent ()
  "A % in the project path is shown literally in the header line (#42)."
  (valsi-terminal-agent-test--with-root
    (let* ((dir (file-name-as-directory (expand-file-name "p%b" root)))
           (default-directory (progn (make-directory dir) dir))
           (label (valsi-project-label (valsi-project-canonical-root dir)))
           (instance (save-window-excursion (valsi-agent "primary" 'pi))))
      (with-current-buffer (valsi-terminal-agent-instance-buffer instance)
        ;; `format-mode-line' renders nothing in batch mode, so check the
        ;; construct: the label appears only with its % doubled.
        (should (member (string-replace "%" "%%" label) header-line-format))
        (should-not (member label header-line-format))))))

(provide 'valsi-terminal-agent-test)
;;; valsi-terminal-agent-test.el ends here

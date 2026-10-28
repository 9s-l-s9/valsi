;;; valsi-app-live-refresh-observation-test.el --- Live refresh observation regressions -*- lexical-binding: t; -*-

;;; Commentary:

;; Regression tests for buffer observation and filesystem watches in
;; `valsi-app-live-refresh'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-app-live-refresh)

(defmacro valsi-app-live-refresh-observation-test--with-root (root &rest body)
  "Run BODY with a temporary canonical ROOT, resetting live refresh after."
  (declare (indent 1))
  `(let ((,root (file-name-as-directory
                 (file-truename (make-temp-file "valsi-live-observe-" t)))))
     (unwind-protect
         (progn ,@body)
       (dolist (buffer (buffer-list))
         (when (and (buffer-live-p buffer)
                    (or (string-prefix-p " *valsi-observe-" (buffer-name buffer))
                        (when-let* ((name (buffer-file-name buffer)))
                          (string-prefix-p ,root (file-truename name)))))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (valsi-app-live-refresh-reset)
       (delete-directory ,root t))))

(defun valsi-app-live-refresh-observation-test--hub (root)
  "Subscribe a fresh hub buffer to ROOT without filesystem watches."
  (cl-letf (((symbol-function 'valsi-app-live-refresh--watch-directory) #'ignore))
    (valsi-app-live-refresh-subscribe
     (generate-new-buffer " *valsi-observe-hub*") root #'ignore)))

(defun valsi-app-live-refresh-observation-test--pending-p (root)
  "Return non-nil when ROOT has a scheduled refresh."
  (and (valsi-app-live-refresh--project-timer
        (valsi-app-live-refresh--project root))
       t))

(ert-deftest valsi-app-live-refresh-observation-survives-revert-and-mode-change ()
  "Regression for #46: observation survives `revert-buffer' and mode changes."
  (valsi-app-live-refresh-observation-test--with-root root
    (let* ((file (expand-file-name "PLAN.md" root))
           (project (valsi-app-live-refresh--project root))
           buffer)
      (with-temp-file file (insert "# Plan\n"))
      (setq buffer (find-file-noselect file))
      (valsi-app-live-refresh-observation-test--hub root)
      (valsi-app-live-refresh--observe-buffer file root)
      (with-current-buffer buffer
        (revert-buffer t t)
        (valsi-app-live-refresh--cancel-work project)
        (insert "y")
        (should (valsi-app-live-refresh-observation-test--pending-p root))
        (valsi-app-live-refresh--cancel-work project)
        (text-mode)
        (insert "z")
        (should (valsi-app-live-refresh-observation-test--pending-p root))))))

(provide 'valsi-app-live-refresh-observation-test)
;;; valsi-app-live-refresh-observation-test.el ends here

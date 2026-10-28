;;; valsi-app-live-refresh-observation-test.el --- Live refresh observation regressions -*- lexical-binding: t; -*-

;;; Commentary:

;; Regression tests for buffer observation and filesystem watches in
;; `valsi-app-live-refresh'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-app-live-refresh)
(require 'valsi-app)

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
  "Subscribe and return a fresh hub buffer for ROOT without watches."
  (let ((hub (generate-new-buffer " *valsi-observe-hub*")))
    (cl-letf (((symbol-function 'valsi-app-live-refresh--watch-directory) #'ignore))
      (valsi-app-live-refresh-subscribe hub root #'ignore))
    hub))

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

(ert-deftest valsi-app-live-refresh-observation-serves-nested-projects ()
  "Regression for #47: a file indexed by nested projects refreshes both hubs."
  (valsi-app-live-refresh-observation-test--with-root outer
    (let* ((inner (file-name-as-directory (expand-file-name "sub" outer)))
           (file (expand-file-name "PLAN.md" inner))
           (outer-project (valsi-app-live-refresh--project outer))
           (inner-project (valsi-app-live-refresh--project inner))
           buffer)
      (make-directory inner)
      (with-temp-file file (insert "# Plan\n"))
      (setq buffer (find-file-noselect file))
      (valsi-app-live-refresh-observation-test--hub outer)
      (let ((inner-hub (valsi-app-live-refresh-observation-test--hub inner)))
        (valsi-app-live-refresh--observe-buffer file outer)
        (valsi-app-live-refresh--observe-buffer file inner)
        (with-current-buffer buffer (insert "x"))
        (should (valsi-app-live-refresh-observation-test--pending-p outer))
        (should (valsi-app-live-refresh-observation-test--pending-p inner))
        ;; Closing the inner hub must keep the outer project's observation.
        (valsi-app-live-refresh-unsubscribe inner-hub inner)
        (valsi-app-live-refresh--cancel-work outer-project)
        (valsi-app-live-refresh--cancel-work inner-project)
        (with-current-buffer buffer
          (should (equal (list outer) valsi-app-live-refresh--buffer-roots))
          (insert "y"))
        (should (valsi-app-live-refresh-observation-test--pending-p outer))
        (should-not (valsi-app-live-refresh-observation-test--pending-p inner))))))

(ert-deftest valsi-app-live-refresh-observation-finds-symlinked-buffers ()
  "Regression for #48: unsaved edits through a symlinked path are modified."
  (valsi-app-live-refresh-observation-test--with-root base
    (let* ((root (file-name-as-directory (expand-file-name "a" base)))
           (alias (expand-file-name "alias" base))
           (file (expand-file-name "PLAN.md" root))
           buffer)
      (make-directory root)
      (make-symbolic-link root alias)
      (with-temp-file file (insert "# Plan\n"))
      (setq buffer (find-file-noselect (expand-file-name "PLAN.md" alias)))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "unsaved\n"))
      (should (eq buffer (valsi-app-live-refresh--file-buffer file)))
      (should
       (equal '("modified")
              (mapcar (lambda (entry) (plist-get entry :state))
                      (valsi-app-live-refresh-reconcile
                       root (list (list :file file :grammar 'plan))))))
      (should (equal "modified" (valsi-app--file-state file)))
      (should (string-match-p "unsaved" (valsi-app--file-text file)))
      (should (eq buffer (plist-get (valsi-app--file-cache-key file) :buffer))))))

(defun valsi-app-live-refresh-observation-test--pump ()
  "Process pending filesystem notification events."
  (dotimes (_ 3) (read-event nil nil 0.2)))

(ert-deftest valsi-app-live-refresh-observation-replaces-stopped-watch ()
  "Regression for #50: a watch of a deleted directory is replaced."
  (skip-unless file-notify--library)
  (valsi-app-live-refresh-observation-test--with-root root
    (let ((doc (file-name-as-directory (expand-file-name "doc" root)))
          (project (valsi-app-live-refresh--project root)))
      (make-directory doc)
      (valsi-app-live-refresh-subscribe
       (generate-new-buffer " *valsi-observe-hub*") root #'ignore)
      (valsi-app-live-refresh--watch-directory project doc)
      (delete-directory doc t)
      (valsi-app-live-refresh-observation-test--pump)
      (make-directory doc)
      (valsi-app-live-refresh-observation-test--pump)
      ;; What the next scan does for a directory with known artifacts.
      (valsi-app-live-refresh--watch-directory project doc)
      (let ((watch (assoc doc (valsi-app-live-refresh--project-watches project))))
        (should watch)
        (should (file-notify-valid-p (cdr watch))))
      (valsi-app-live-refresh--cancel-work project)
      (with-temp-file (expand-file-name "M.md" doc) (insert "m"))
      (valsi-app-live-refresh-observation-test--pump)
      (should (valsi-app-live-refresh-observation-test--pending-p root)))))

(ert-deftest valsi-app-live-refresh-observation-rewatches-invalid-entry ()
  "Regression for #50: an invalid descriptor never blocks a new watch."
  (skip-unless file-notify--library)
  (valsi-app-live-refresh-observation-test--with-root root
    (let ((project (valsi-app-live-refresh--project root)))
      (valsi-app-live-refresh--watch-directory project root)
      (let ((stale (cdr (assoc root (valsi-app-live-refresh--project-watches
                                     project)))))
        (file-notify-rm-watch stale)
        (valsi-app-live-refresh--watch-directory project root)
        (let ((watches (valsi-app-live-refresh--project-watches project)))
          (should (= 1 (length watches)))
          (should (file-notify-valid-p (cdar watches))))))))

(ert-deftest valsi-app-live-refresh-observation-watches-new-subdirectories ()
  "Regression for #52: files added to a new subdirectory refresh the hub."
  (skip-unless file-notify--library)
  (valsi-app-live-refresh-observation-test--with-root root
    (let ((docs (file-name-as-directory (expand-file-name "docs" root)))
          (deep (file-name-as-directory (expand-file-name "docs/deep" root)))
          (git (file-name-as-directory (expand-file-name ".git" root)))
          (project (valsi-app-live-refresh--project root)))
      (valsi-app-live-refresh-subscribe
       (generate-new-buffer " *valsi-observe-hub*") root #'ignore)
      (make-directory deep t)
      (make-directory git)
      (valsi-app-live-refresh-observation-test--pump)
      (let ((watched (mapcar #'car (valsi-app-live-refresh--project-watches
                                    project))))
        (should (member docs watched))
        (should (member deep watched))
        (should-not (member git watched)))
      (valsi-app-live-refresh--cancel-work project)
      (with-temp-file (expand-file-name "NEW.md" deep)
        (insert "# New\n- [ ] T9 y\n"))
      (valsi-app-live-refresh-observation-test--pump)
      (should (valsi-app-live-refresh-observation-test--pending-p root)))))

(provide 'valsi-app-live-refresh-observation-test)
;;; valsi-app-live-refresh-observation-test.el ends here

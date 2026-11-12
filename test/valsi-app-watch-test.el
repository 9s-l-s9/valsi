;;; valsi-app-watch-test.el --- Bounded watch discovery tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Exercise ignore rules, cooperative discovery, watch limits, and retries.

;;; Code:

(require 'ert)
(require 'valsi-app)
(require 'valsi-test-refresh)

(defmacro valsi-app-watch--with-project (&rest body)
  "Run BODY with ROOT, PROJECT and fake watch descriptors."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "valsi-watches-" t))))
          (project (valsi-app-live-refresh--project root))
          (hub (generate-new-buffer " *valsi-watch-test*"))
          (valsi-app-live-refresh-time-budget 10)
          (valsi-app-live-refresh-step-limit 2)
          (next-watch 0))
     (unwind-protect
         (cl-letf (((symbol-function 'file-notify-add-watch)
                    (lambda (&rest _) (cl-incf next-watch)))
                   ((symbol-function 'file-notify-valid-p) (lambda (_) t))
                   ((symbol-function 'file-notify-rm-watch) #'ignore)
                   ;; Temporary parents may contain unrelated/incomplete Git
                   ;; metadata. Only the Git-specific test uses real discovery.
                   ((symbol-function 'project-current) (lambda (&rest _) nil))
                   ((symbol-function 'input-pending-p) (lambda () nil)))
           (valsi-app-live-refresh-subscribe hub root #'ignore)
           ,@body)
       (kill-buffer hub)
       (valsi-app-live-refresh-reset root)
       (delete-directory root t))))

(ert-deftest valsi-app-watch-notification-only-queues-and-worker-yields ()
  "Directory events do no recursive IO; each timer turn is bounded (#99)."
  (valsi-app-watch--with-project
    (let ((docs (expand-file-name "docs/" root)))
      (dotimes (i 100) (make-directory (expand-file-name (format "d%d" i) docs) t))
      (cl-letf (((symbol-function 'directory-files)
                 (lambda (&rest _) (ert-fail "walk in notification callback"))))
        (valsi-app-live-refresh--notify root (list 1 'created docs)))
      (should (= 1 (hash-table-count (valsi-app-live-refresh--project-watches project))))
      (valsi-test-refresh-step root)
      (should (valsi-app-live-refresh--project-iterator project))
      ;; The first turn can watch docs and examine two child entries only.
      (should (<= (hash-table-count (valsi-app-live-refresh--project-watches project)) 3))
      (valsi-test-refresh-drain root)
      (should (= 102 (hash-table-count (valsi-app-live-refresh--project-watches project))))
      (valsi-app-live-refresh--cancel-work project)
      (valsi-app-live-refresh--notify root (list 1 'changed (expand-file-name "output.o" docs)))
      (should-not (valsi-app-live-refresh--project-timer project)))))

(ert-deftest valsi-app-watch-git-prunes-ignored-trees-and-honors-nested-rules ()
  "Git ignores, including negations, prevent entering build trees (#99)."
  (skip-unless (executable-find "git"))
  (valsi-app-watch--with-project
   (let ((project-vc-ignores '("extra/")))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) (list 'vc 'Git root))))
    (should (zerop (call-process "git" nil nil nil "init" "-q" root)))
    (with-temp-file (expand-file-name ".gitignore" root)
      (insert "target/\n.venv/\n"))
    (make-directory (expand-file-name "docs/open/deep" root) t)
    (with-temp-file (expand-file-name "docs/.gitignore" root)
      (insert "*\n!open/\n"))
    (dotimes (i 200)
      (make-directory (expand-file-name (format "target/build/%d/objects" i) root) t))
    (make-directory (expand-file-name ".venv/lib/site-packages" root) t)
    (make-directory (expand-file-name "extra/generated" root) t)
    (make-directory (expand-file-name "docs/private/hidden" root) t)
    ;; A more specific nested rule keeps the contents of open/ visible.
    (with-temp-file (expand-file-name "docs/open/.gitignore" root) (insert "!*\n"))
    (let ((read-directory (symbol-function 'directory-files)) visited)
      (cl-letf (((symbol-function 'directory-files)
                 (lambda (directory &rest args)
                   (push (file-relative-name directory root) visited)
                   (apply read-directory directory args))))
        (dolist (directory '("target/" ".venv/" "docs/" "extra/"))
          (valsi-app-live-refresh--notify root (list 1 'created (expand-file-name directory root))))
        (valsi-test-refresh-drain root))
      (should-not (seq-some (lambda (path) (string-match-p "target\\|venv\\|private\\|extra" path)) visited)))
    (let ((watches (valsi-app-live-refresh--project-watches project)))
      (should (gethash (expand-file-name "docs/open/deep/" root) watches))
      (should-not (gethash (expand-file-name "target/" root) watches))
      (should-not (gethash (expand-file-name "docs/private/" root) watches)))
    ;; Changes to ignore rules release watches that were previously useful.
    (with-temp-file (expand-file-name ".gitignore" root) (insert "docs/\ntarget/\n.venv/\n"))
    (valsi-app-live-refresh--notify root (list 1 'changed (expand-file-name ".gitignore" root)))
    (valsi-test-refresh-drain root)
    (should (= 1 (hash-table-count (valsi-app-live-refresh--project-watches project))))))))

(ert-deftest valsi-app-watch-backend-globs-cover-descendants ()
  "Rooted backend ignores apply to existing descendant watches too."
  (should (valsi-app-live-refresh--glob-ignored-p
           "/project/" "/project/docs/generated/deep/" '("./docs/generated/")))
  (should-not (valsi-app-live-refresh--glob-ignored-p
               "/project/" "/project/other/docs/generated/" '("./docs/generated/")))
  (should (valsi-app-live-refresh--glob-ignored-p
           "/project/" "/project/src/build/deep/" '("build/"))))

(ert-deftest valsi-app-watch-cap-is-visible-and-explicit-refresh-retries ()
  "A cap bounds resources; lifting it and refreshing resumes queued work."
  (valsi-app-watch--with-project
    (let ((valsi-app-live-refresh-watch-limit 3)
          (docs (expand-file-name "docs/" root)))
      (dotimes (i 10) (make-directory (expand-file-name (format "%d" i) docs) t))
      (valsi-app-live-refresh--notify root (list 1 'created docs))
      (valsi-test-refresh-drain root)
      (should (= 3 (hash-table-count (valsi-app-live-refresh--project-watches project))))
      (should (string-match-p "Watch limit reached.*press g"
                              (valsi-app-live-refresh--project-status project)))
      (setq valsi-app-live-refresh-watch-limit 20)
      (valsi-app-live-refresh-schedule root nil t)
      (valsi-test-refresh-drain root)
      (should (= 12 (hash-table-count (valsi-app-live-refresh--project-watches project))))
      (should-not (valsi-app-live-refresh--project-status project)))))

(ert-deftest valsi-app-watch-errors-remain-visible-and-do-not-stop-scans ()
  "Backend errors are reported while artifact snapshots can still complete."
  (valsi-app-watch--with-project
    (let ((docs (expand-file-name "docs/" root)))
      (make-directory docs)
      (cl-letf (((symbol-function 'file-notify-add-watch)
                 (lambda (&rest _) (signal 'file-notify-error '("exhausted")))))
        (valsi-app-live-refresh--notify root (list 1 'created docs))
        (valsi-test-refresh-drain root))
      (should (string-match-p "Cannot watch.*exhausted.*press g"
                              (valsi-app-live-refresh--project-status project)))
      (should-not (valsi-app-live-refresh--project-iterator project)))))

(ert-deftest valsi-app-watch-cancelled-discovery-resumes-remaining-children ()
  "Cancelling an iterator mid-directory does not lose its remaining children."
  (valsi-app-watch--with-project
    (let ((docs (expand-file-name "docs/" root)))
      (dotimes (i 8) (make-directory (expand-file-name (format "%d" i) docs) t))
      (valsi-app-live-refresh--notify root (list 1 'created docs))
      (valsi-test-refresh-step root)
      (valsi-app-live-refresh-schedule root)
      (valsi-test-refresh-drain root)
      (should (= 10 (hash-table-count (valsi-app-live-refresh--project-watches project)))))))

(ert-deftest valsi-app-watch-project-candidates-watch-all-ancestors-once ()
  "Non-Markdown project files also establish watches for future artifacts."
  (valsi-app-watch--with-project
    (let ((file (expand-file-name "src/deep/file.c" root)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert "source"))
      (cl-letf (((symbol-function 'valsi-app--project-candidates) (lambda (_) (list file file))))
        (should-not (valsi-app--project-files root)))
      (should (= 3 next-watch))
      (should (gethash (expand-file-name "src/" root)
                       (valsi-app-live-refresh--project-watches project))))))

(provide 'valsi-app-watch-test)
;;; valsi-app-watch-test.el ends here

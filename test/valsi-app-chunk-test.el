;;; valsi-app-chunk-test.el --- Cooperative project refresh tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Drive individual timer turns to check bounded work and interleaved edits.
;; One integration test uses real timers to prove unrelated work can run.

;;; Code:

(require 'ert)
(require 'valsi)
(require 'valsi-test-refresh)

(defmacro valsi-app-chunk-test--with-project (&rest body)
  "Run BODY with six plan FILES in ROOT, a HUB, and refresh PROJECT state."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "valsi-chunks-" t)))
          (valsi-global-mode nil)
          (valsi-app-auto-sidebar nil)
          (valsi-app-live-refresh-step-limit 2)
          (valsi-app-live-refresh-time-budget 10)
          (discoveries 0)
          files hub sidebar project)
     (unwind-protect
         (cl-letf (((symbol-function 'valsi-app--project-candidates)
                    (lambda (_) (cl-incf discoveries) files))
                   ((symbol-function 'valsi-app-live-refresh--watch-directory) #'ignore)
                   ((symbol-function 'input-pending-p) (lambda () nil)))
           (dotimes (n 6)
             (let ((file (expand-file-name (format "%02d/PLAN.md" n) root)))
               (make-directory (file-name-directory file) t)
               (with-temp-file file (insert "- [ ] T001 First\n"))
               (push file files)))
           (setq files (nreverse files)
                 hub (valsi-app--buffer root nil)
                 project (valsi-app-live-refresh--project root))
           ,@body)
       (dolist (file files)
         (when-let* ((buffer (get-file-buffer file)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (when (buffer-live-p hub) (kill-buffer hub))
       (when (buffer-live-p sidebar) (kill-buffer sidebar))
       (valsi-app-live-refresh-reset root)
       (delete-directory root t))))

(ert-deftest valsi-app-chunk-cold-open-yields-and-shares-complete-snapshot ()
  "Opening views does no discovery; each turn does bounded work before publish."
  (valsi-app-chunk-test--with-project
    (setq sidebar (valsi-app--buffer root t))
    (should (= 0 discoveries))
    (should-not (buffer-local-value 'valsi-app--entries hub))
    (with-current-buffer hub
      (should (string-match-p "Refreshing artifacts" (buffer-string))))
    (valsi-test-refresh-step root)
    (should (= 1 discoveries))
    (let ((cache (valsi-app-live-refresh--project-cache project)))
      (while (valsi-app-live-refresh--project-timer project)
        (let ((before (hash-table-count cache)))
          (valsi-test-refresh-step root)
          (should (<= (- (hash-table-count cache) before) 2)))
        (when (valsi-app-live-refresh--project-iterator project)
          (should-not (valsi-app-live-refresh--project-initialized project))
          (should-not (buffer-local-value 'valsi-app--entries hub)))))
    (should (= 1 discoveries))
    (should (= 6 (length (buffer-local-value 'valsi-app--entries hub))))
    (should (eq (buffer-local-value 'valsi-app--entries hub)
                (buffer-local-value 'valsi-app--entries sidebar)))
    (should-not (buffer-local-value 'valsi-app--refresh-status hub))))

(ert-deftest valsi-app-chunk-budget-and-pending-input-stop-work ()
  "Time and pending-input limits stop a turn even below the step limit."
  (valsi-app-chunk-test--with-project
    (let ((valsi-app-live-refresh-time-budget 0.01)
          (valsi-app-live-refresh-step-limit 1000)
          (clock -0.02))
      (cl-letf (((symbol-function 'float-time)
                 (lambda (&optional _) (cl-incf clock 0.02))))
        (valsi-test-refresh-step root))
      ;; Only candidate discovery ran; processing files needs another turn.
      (should (= 1 discoveries))
      (should (= 0 (hash-table-count (valsi-app-live-refresh--project-cache project))))
      (let ((iterator (valsi-app-live-refresh--project-iterator project)))
        (cancel-timer (valsi-app-live-refresh--project-timer project))
        (cl-letf (((symbol-function 'input-pending-p) (lambda () t)))
          (valsi-app-live-refresh--continue project iterator))
        (should (eq iterator (valsi-app-live-refresh--project-iterator project)))
        (should (= 0 (hash-table-count (valsi-app-live-refresh--project-cache project)))))
      (should (timerp (valsi-app-live-refresh--project-timer project))))))

(ert-deftest valsi-app-chunk-edit-cancels-stale-work-without-losing-content ()
  "An edit mid-scan supersedes the old iterator and remains authoritative."
  (valsi-app-chunk-test--with-project
    (let* ((file (car files))
           (source (find-file-noselect file)))
      (while (not (gethash file (valsi-app-live-refresh--project-cache project)))
        (valsi-test-refresh-step root))
      (let ((old (valsi-app-live-refresh--project-iterator project)))
        (with-current-buffer source
          (goto-char (point-max))
          (insert "- [ ] T002 Unsaved\n"))
        (should-not (valsi-app-live-refresh--project-iterator project))
        (let ((timer (valsi-app-live-refresh--project-timer project)))
          (valsi-app-live-refresh--continue project old)
          (should (eq timer (valsi-app-live-refresh--project-timer project))))
        (should-not (valsi-app-live-refresh--project-initialized project)))
      (valsi-test-refresh-drain root)
      (let ((entry (car (buffer-local-value 'valsi-app--entries hub))))
        (should (equal "2 open" (plist-get entry :summary)))
        (should (equal "modified" (plist-get entry :state))))
      (with-current-buffer source
        (should (buffer-modified-p))
        (should (string-match-p "Unsaved" (buffer-string))))
      (with-temp-buffer
        (insert-file-contents file)
        (should-not (string-match-p "Unsaved" (buffer-string))))
      ;; Closing a visiting buffer also changes the analyzed source revision.
      (with-current-buffer source (set-buffer-modified-p nil))
      (kill-buffer source)
      (valsi-test-refresh-drain root)
      (let ((entry (car (buffer-local-value 'valsi-app--entries hub))))
        (should (equal "1 open" (plist-get entry :summary)))
        (should (equal "clean" (plist-get entry :state)))))))

(ert-deftest valsi-app-chunk-filesystem-change-keeps-old-view-until-ready ()
  "A disk event restarts discovery; all views see the same new/missing rows."
  (valsi-app-chunk-test--with-project
    (setq sidebar (valsi-app--buffer root t))
    (valsi-test-refresh-drain root)
    (let ((snapshot (valsi-app-live-refresh--project-snapshot project))
          (removed (car files))
          (new (expand-file-name "new/PLAN.md" root)))
      (with-current-buffer hub (valsi-app-refresh))
      (valsi-test-refresh-step root)
      (delete-file removed)
      (make-directory (file-name-directory new))
      (with-temp-file new (insert "- [x] T001 New\n"))
      (setq files (append (cdr files) (list new)))
      (valsi-app-live-refresh--notify root nil)
      (should (eq snapshot (buffer-local-value 'valsi-app--entries hub)))
      (valsi-test-refresh-drain root)
      (let ((entries (buffer-local-value 'valsi-app--entries hub)))
        (should (eq entries (buffer-local-value 'valsi-app--entries sidebar)))
        (should (equal "missing" (plist-get (car entries) :state)))
        (should (equal "new" (plist-get (car (last entries)) :state)))
        (should (= 7 (length entries)))))))

(ert-deftest valsi-app-chunk-lost-event-and-grammar-reload-revalidate ()
  "Signature and grammar checks reject stale analysis even without events."
  (valsi-app-chunk-test--with-project
    (let ((file (car files)))
      (while (not (gethash file (valsi-app-live-refresh--project-cache project)))
        (valsi-test-refresh-step root))
      (with-temp-file file (insert "- [x] T001 Changed without notification\n"))
      (valsi-registry-register (valsi-registry-get 'plan))
      (valsi-test-refresh-drain root)
      (should (>= discoveries 2))
      (should (equal "1 done" (plist-get (car (buffer-local-value 'valsi-app--entries hub))
                                         :summary)))
      (should-not (valsi-app-live-refresh--project-status project)))))

(ert-deftest valsi-app-chunk-last-subscriber-cancels-all-work ()
  "Closing the final view or resetting a project makes stale callbacks inert."
  (valsi-app-chunk-test--with-project
    (setq sidebar (valsi-app--buffer root t))
    (valsi-test-refresh-step root)
    (let ((iterator (valsi-app-live-refresh--project-iterator project)))
      (kill-buffer hub)
      (should (eq iterator (valsi-app-live-refresh--project-iterator project)))
      (kill-buffer sidebar)
      (should-not (valsi-app-live-refresh--project-timer project))
      (should-not (valsi-app-live-refresh--project-iterator project))
      (valsi-app-live-refresh--continue project iterator)
      (valsi-app-live-refresh--notify root nil)
      (should-not (valsi-app-live-refresh--project-timer project)))
    (setq hub (valsi-app--buffer root nil))
    (let ((token (valsi-app-live-refresh--project-request-token project)))
      (valsi-app-live-refresh-reset root)
      (valsi-app-live-refresh--dispatch project token)
      (valsi-app-live-refresh--notify root nil)
      (should-not (gethash root valsi-app-live-refresh--projects)))))

(ert-deftest valsi-app-chunk-error-preserves-snapshot-and-retry-works ()
  "Discovery errors leave existing rows visible and permit an explicit retry."
  (valsi-app-chunk-test--with-project
    (valsi-test-refresh-drain root)
    (let ((snapshot (buffer-local-value 'valsi-app--entries hub)))
      (with-current-buffer hub (valsi-app-refresh))
      (cl-letf (((symbol-function 'valsi-app--project-candidates)
                 (lambda (_) (error "Backend unavailable"))))
        (valsi-test-refresh-drain root))
      (should (eq snapshot (buffer-local-value 'valsi-app--entries hub)))
      (should (string-match-p "Backend unavailable"
                              (buffer-local-value 'valsi-app--refresh-status hub)))
      (with-current-buffer hub (valsi-app-refresh))
      (valsi-test-refresh-drain root)
      (should-not (buffer-local-value 'valsi-app--refresh-status hub)))))

(ert-deftest valsi-app-chunk-real-timers-allow-unrelated-work ()
  "Another timer runs while a cold project is still being analyzed."
  (valsi-app-chunk-test--with-project
    (let ((valsi-app-live-refresh-step-limit 1)
          (deadline (+ (float-time) 5))
          observed timer)
      (unwind-protect
          (progn
            (setq timer
                  (run-at-time
                   0.003 0.003
                   (lambda ()
                     (when (and (valsi-app-live-refresh--project-iterator project)
                                (> (hash-table-count
                                    (valsi-app-live-refresh--project-cache project)) 0)
                                (not (valsi-app-live-refresh--project-initialized project)))
                       (setq observed t)))))
            (while (and (valsi-app-live-refresh--project-timer project)
                        (< (float-time) deadline))
              (accept-process-output nil 0.02))
            (should-not (valsi-app-live-refresh--project-timer project))
            (should observed)
            (should (= 6 (length (buffer-local-value 'valsi-app--entries hub)))))
        (when timer (cancel-timer timer))))))

(provide 'valsi-app-chunk-test)
;;; valsi-app-chunk-test.el ends here

;;; valsi-app-live-refresh-test.el --- Tests for Valsi app refresh -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'valsi-app-live-refresh)

(cl-defmacro valsi-app-live-refresh-test--with-project
    ((root file buffer) &rest body)
  "Run BODY with a temporary ROOT, artifact FILE, and visiting BUFFER."
  (declare (indent 1))
  `(let* ((,root (make-temp-file "valsi-live-refresh-" t))
          (,file (expand-file-name "PLAN.md" ,root))
          (,buffer nil))
     (unwind-protect
         (progn
           (with-temp-file ,file (insert "# Plan\n"))
           (setq ,buffer (find-file-noselect ,file))
           ,@body)
       (when (buffer-live-p ,buffer)
         (with-current-buffer ,buffer
           (set-buffer-modified-p nil))
         (kill-buffer ,buffer))
       (valsi-app-live-refresh-reset ,root)
       (delete-directory ,root t))))

(ert-deftest valsi-app-live-refresh-reconciles-buffer-and-disk-states ()
  (valsi-app-live-refresh-test--with-project (root file buffer)
    (let ((entry (list :file file :grammar 'speckit)))
      (should
       (equal "open"
              (plist-get
               (car (valsi-app-live-refresh-reconcile root (list entry)))
               :state)))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "unsaved\n"))
      (should
       (equal "modified"
              (plist-get
               (car (valsi-app-live-refresh-reconcile root (list entry)))
               :state)))
      ;; Change the visited file behind the unsaved buffer.  Valsi must report
      ;; the collision without reverting either source.
      (with-temp-file file (insert "# External\n"))
      ;; `verify-visited-file-modtime' deliberately tolerates very small
      ;; timestamp differences on coarse filesystems.
      (set-file-times file (time-add (current-time) 10))
      (should
       (equal "conflict"
              (plist-get
               (car (valsi-app-live-refresh-reconcile root (list entry)))
               :state)))
      (with-current-buffer buffer
        (should (buffer-modified-p))
        (should (string-match-p "unsaved" (buffer-string)))))))

(ert-deftest valsi-app-live-refresh-reconciles-new-changed-and-missing ()
  (let* ((root (make-temp-file "valsi-live-refresh-" t))
         (one (expand-file-name "one.md" root))
         (two (expand-file-name "two.md" root))
         (entry-one (list :file one :grammar 'speckit))
         (entry-two (list :file two :grammar 'generic-agents)))
    (unwind-protect
        (progn
          (with-temp-file one (insert "# One\n"))
          (should
           (equal "clean"
                  (plist-get
                   (car (valsi-app-live-refresh-reconcile
                         root (list entry-one)))
                   :state)))
          (with-temp-file two (insert "# Two\n"))
          (let ((entries
                 (valsi-app-live-refresh-reconcile
                  root (list entry-one entry-two))))
            (should
             (equal "new"
                    (plist-get
                     (seq-find
                      (lambda (entry)
                        (equal (plist-get entry :file) two))
                      entries)
                     :state))))
          (with-temp-file one (insert "# Changed contents and size\n"))
          (should
           (equal "changed on disk"
                  (plist-get
                   (car (valsi-app-live-refresh-reconcile
                         root (list entry-one entry-two)))
                   :state)))
          (delete-file one)
          (let* ((entries
                  (valsi-app-live-refresh-reconcile root (list entry-two)))
                 (missing
                  (seq-find
                   (lambda (entry)
                     (equal (plist-get entry :file) one))
                   entries)))
            (should missing)
            (should (equal "missing" (plist-get missing :state)))))
      (valsi-app-live-refresh-reset root)
      (delete-directory root t))))

(ert-deftest valsi-app-live-refresh-save-advances-own-write-baseline ()
  (valsi-app-live-refresh-test--with-project (root file buffer)
    (let ((entry (list :file file :grammar 'speckit)))
      (valsi-app-live-refresh-reconcile root (list entry))
      (cl-letf (((symbol-function 'valsi-app-live-refresh-schedule)
                 #'ignore))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "saved\n")
          (save-buffer)))
      (should
       (equal "open"
              (plist-get
               (car (valsi-app-live-refresh-reconcile root (list entry)))
               :state))))))

(ert-deftest valsi-app-live-refresh-debounces-scheduled-work ()
  (let ((root (make-temp-file "valsi-live-refresh-" t))
        scheduled
        cancelled)
    (unwind-protect
        (cl-letf (((symbol-function 'run-with-idle-timer)
                   (lambda (_delay _repeat function &rest arguments)
                     (let ((token (list function arguments)))
                       (push token scheduled)
                       token)))
                  ((symbol-function 'cancel-timer)
                   (lambda (timer) (push timer cancelled))))
          (valsi-app-live-refresh-schedule root)
          (valsi-app-live-refresh-schedule root)
          (should (= 2 (length scheduled)))
          (should (= 1 (length cancelled)))
          (pcase-let ((`(,function ,arguments) (car scheduled)))
            (apply function arguments)))
      (valsi-app-live-refresh-reset root)
      (delete-directory root t))))

(ert-deftest valsi-app-live-refresh-observes-artifacts-visited-later ()
  (let* ((root (make-temp-file "valsi-live-refresh-" t))
         (file (expand-file-name "PLAN.md" root))
         (hub (generate-new-buffer " *valsi-live-hub*"))
         buffer
         scheduled)
    (unwind-protect
        (progn
          (with-temp-file file (insert "# Plan\n"))
          (valsi-app-live-refresh-reconcile
           root (list (list :file file :grammar 'speckit)))
          (cl-letf (((symbol-function
                      'valsi-app-live-refresh--ensure-watches)
                     #'ignore))
            (valsi-app-live-refresh-subscribe hub root #'ignore))
          (setq buffer (find-file-noselect file))
          (cl-letf (((symbol-function 'valsi-app-live-refresh-schedule)
                     (lambda (changed-root)
                       (setq scheduled changed-root))))
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "edit\n")))
          (should
           (equal (file-name-as-directory (file-truename root)) scheduled)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (when (buffer-live-p hub) (kill-buffer hub))
      (valsi-app-live-refresh-reset root)
      (delete-directory root t))))

(provide 'valsi-app-live-refresh-test)
;;; valsi-app-live-refresh-test.el ends here

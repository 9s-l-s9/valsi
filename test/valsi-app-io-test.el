;;; valsi-app-io-test.el --- Bound sidebar and discovery I/O -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Count operations instead of time: cursor-driven renders must not stat the
;; project, and classification should not read every generic document in full.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi)
(require 'valsi-app)

(ert-deftest valsi-app-io-sidebar-does-not-probe-artifact-files ()
  "Rendering thousands of entries uses memory for file identity and attention."
  (let* ((source (generate-new-buffer " *valsi-io-source*"))
         (sidebar (generate-new-buffer " *valsi-io-sidebar*"))
         (root "/tmp/valsi-io/")
         (file (concat root "PLAN.md"))
         (valsi-terminal-agent--instances (make-hash-table :test #'equal))
         (entries (append
                   (cl-loop for i below 3000
                            collect (list :file (format "%sdoc-%d.md" root i)
                                          :grammar 'generic :state "clean"))
                   (list (list :file file :truename file :buffer source
                               :grammar 'plan :state "open" :warnings 2)))))
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "- [ ] T001 Context\n")
            (setq buffer-file-name "/alias/PLAN.md" buffer-file-truename file
                  valsi--grammar 'plan))
          (with-current-buffer sidebar
            (valsi-app-mode)
            (setq valsi-app--root root valsi-app--entries entries
                  valsi-app--compact t valsi-app--source-buffer source)
            (cl-letf (((symbol-function 'file-equal-p)
                       (lambda (&rest _) (ert-fail "File identity probe during render")))
                      ((symbol-function 'file-attributes)
                       (lambda (&rest _) (ert-fail "Stat during render")))
                      ((symbol-function 'file-truename)
                       (lambda (&rest _) (ert-fail "Canonicalization during render")))
                      ((symbol-function 'find-buffer-visiting)
                       (lambda (&rest _) (ert-fail "Alias probe during render")))
                      ;; Agent lookup receives the hub's already canonical root.
                      ((symbol-function 'valsi-project-canonical-root) #'identity))
              (valsi-app--render)
              (should (string-search "2 warnings" (buffer-string)))
              (should (string-search "1 attention" (buffer-string)))
              (let ((index valsi-app--entry-index))
                (valsi-app--render)
                (should (eq index valsi-app--entry-index))
                (setq valsi-app--entries
                      (list (list :file file :truename file :buffer source
                                  :grammar 'plan :state "open" :warnings 5)))
                (valsi-app--render)
                (should-not (eq index valsi-app--entry-index))
                (should (string-search "5 warnings" (buffer-string))))
              (setq valsi-app--entries nil)
              (valsi-app--render)
              (should-not (valsi-app--entry-for-file file)))))
      (kill-buffer source)
      (kill-buffer sidebar))))

(ert-deftest valsi-app-io-context-signature-tracks-file-identity ()
  "Renaming a source changes its context signature without a filesystem query."
  (with-temp-buffer
    (setq buffer-file-name "/tmp/old.md" buffer-file-truename "/tmp/old.md")
    (let ((old (valsi-app-context-signature (current-buffer))))
      (setq buffer-file-name "/tmp/new.md" buffer-file-truename "/tmp/new.md")
      (should-not (equal old (valsi-app-context-signature (current-buffer)))))))

(ert-deftest valsi-app-io-reconciliation-caches-alias-identity ()
  "The batched scan records canonical names and visiting buffers for aliases."
  (let* ((directory (file-name-as-directory (make-temp-file "valsi-io-" t)))
         (file (expand-file-name "PLAN.md" directory))
         (alias (expand-file-name "alias.md" directory))
         (valsi-global-mode nil)
         buffer)
    (unwind-protect
        (progn
          (with-temp-file file (insert "- [ ] T001 Task\n"))
          (make-symbolic-link file alias)
          (setq buffer (find-file-noselect alias))
          (let* ((snapshot (valsi-app-live-refresh-reconcile
                            directory (list (list :file file :grammar 'plan))))
                 (entry (car snapshot)))
            (should (equal (file-truename file) (plist-get entry :truename)))
            (should (eq buffer (plist-get entry :buffer)))
            (with-temp-buffer
              (setq valsi-app--entries snapshot)
              (should (eq entry (valsi-app--entry-for-file file))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (valsi-app-live-refresh-reset directory)
      (delete-directory directory t))))

(defmacro valsi-app-io-test--with-file (name content &rest body)
  "Run BODY with FILE named NAME, containing CONTENT, and recorded read bounds."
  (declare (indent 2) (debug t))
  `(let* ((directory (make-temp-file "valsi-head-" t))
          (file (expand-file-name ,name directory))
          (valsi-app-detect-head-bytes 64)
          (valsi-app-max-file-bytes 20000)
          (cache (make-hash-table :test #'equal))
          (reader (symbol-function 'insert-file-contents))
          reads)
     (valsi-init)
     (unwind-protect
         (progn
           (with-temp-file file (insert ,content))
           (cl-letf (((symbol-function 'insert-file-contents)
                      (lambda (name &optional visit beg end replace)
                        (when (equal name file) (push end reads))
                        (funcall reader name visit beg end replace))))
             ,@body))
       (when-let* ((buffer (get-file-buffer file)))
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (delete-directory directory t))))

(ert-deftest valsi-app-io-generic-file-reads-only-head ()
  "Unrecognized unopened Markdown is read only to the classification limit."
  (valsi-app-io-test--with-file "notes.md" (make-string 5000 ?x)
    (should (eq 'generic (plist-get (valsi-app--analyze-file file cache) :grammar)))
    (should (equal '(64) reads))
    (setq reads nil)
    (valsi-app--analyze-file file cache)
    (should-not reads)))

(ert-deftest valsi-app-io-recognized-file-gets-complete-summary ()
  "Both named and content-detected plans parse tasks beyond the detection head."
  (dolist (name '("PLAN.md" "notes.md"))
    (valsi-app-io-test--with-file name
        (concat "- [ ] T001 First\n" (make-string 1000 ?x) "\n- [ ] T002 Last\n")
      (should (eq 'plan (plist-get (valsi-app--analyze-file file cache) :grammar)))
      (should (= 2 (length (valsi-node-of-type (plist-get (gethash file cache) :tree) 'task))))
      (should (equal (if (equal name "PLAN.md") '(20000) '(20000 64)) reads)))))

(ert-deftest valsi-app-io-detection-limit-invalidates-cache ()
  "Changing the head limit reclassifies unchanged files for tail-based grammars."
  (valsi-app-io-test--with-file "notes.md"
      (concat (make-string 1000 ?x) "\n- [ ] T001 Last\n")
    (should (eq 'generic (plist-get (valsi-app--analyze-file file cache) :grammar)))
    (setq valsi-app-detect-head-bytes nil reads nil)
    (should (eq 'plan (plist-get (valsi-app--analyze-file file cache) :grammar)))
    (should (equal '(20000) reads))))

(ert-deftest valsi-app-io-open-buffer-keeps-full-unsaved-text ()
  "Open buffers use full text even when the head and disk-analysis limits are small."
  (valsi-app-io-test--with-file "notes.md" (make-string 1000 ?x)
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (insert "\n- [ ] T001 Unsaved\n"))
    (setq valsi-app-max-file-bytes 64 reads nil)
    (should (eq 'plan (plist-get (valsi-app--analyze-file file cache) :grammar)))
    (should-not reads)
    (should (equal "T001"
                   (valsi-node-prop
                    (car (valsi-node-of-type (plist-get (gethash file cache) :tree) 'task))
                    :id)))))

(provide 'valsi-app-io-test)
;;; valsi-app-io-test.el ends here

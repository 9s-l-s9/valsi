;;; valsi-core-test.el --- Regression tests for the artifact minor mode -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Buffer lifecycle and state regressions of `valsi-artifact-minor-mode':
;; clones, reverts, the header line, grammar changes, non-file buffers and
;; grammar commands invoked directly in Browse state.

;;; Code:

(require 'ert)
(require 'valsi)

(defun valsi-core-test--with-file (name content fn)
  "Visit a temporary file NAME holding CONTENT and call FN in its buffer."
  (let* ((dir (make-temp-file "valsi-core" t))
         (file (expand-file-name name dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file (insert content))
          (with-current-buffer (find-file-noselect file)
            (unwind-protect (funcall fn)
              (set-buffer-modified-p nil)
              (kill-buffer))))
      (delete-directory dir t))))

(defconst valsi-core-test--plan "# Plan\n\n- [ ] T001 first\n"
  "A minimal plan artifact.")

;;;; #71: indirect clones keep their own document

(ert-deftest valsi-core-test-killing-clone-keeps-base-open ()
  "Killing an indirect clone does not close the base buffer's document."
  (valsi-init)
  (valsi-core-test--with-file
   "PLAN.md" valsi-core-test--plan
   (lambda ()
     (valsi-artifact-minor-mode 1)
     (let ((uri buffer-file-name))
       (kill-buffer (clone-indirect-buffer "valsi-core-clone" nil))
       (should (member uri (valsi-proto-open-uris)))
       (should (valsi-proto-request
                'artifact/planContext (list :uri uri :taskId "T001")))))))

(ert-deftest valsi-core-test-editing-clone-keeps-base-open ()
  "Editing an indirect clone opens its own document beside the base's."
  (valsi-init)
  (valsi-core-test--with-file
   "PLAN.md" valsi-core-test--plan
   (lambda ()
     (valsi-artifact-minor-mode 1)
     (let ((uri buffer-file-name)
           (clone (clone-indirect-buffer "valsi-core-clone2" nil)))
       (unwind-protect
           (with-current-buffer clone
             (should-not valsi--open-uri)
             (let ((inhibit-read-only t))
               (goto-char (point-max))
               (insert "- [ ] T002 second\n"))
             (valsi-refresh)
             (should (member uri (valsi-proto-open-uris)))
             (should (member (buffer-name) (valsi-proto-open-uris))))
         (with-current-buffer clone (set-buffer-modified-p nil))
         (kill-buffer clone))
       (should (member uri (valsi-proto-open-uris)))))))

;;;; #72: revert keeps the interaction state consistent

(ert-deftest valsi-core-test-revert-keeps-state-consistent ()
  "Reverting with `valsi-global-mode' never leaves Browse on a writable buffer."
  (valsi-init)
  (let ((global valsi-global-mode))
    (unwind-protect
        (progn
          (valsi-global-mode 1)
          (valsi-core-test--with-file
           "PLAN.md" valsi-core-test--plan
           (lambda ()
             (should valsi-artifact-minor-mode)
             (valsi-enter-insert)
             (revert-buffer t t)
             (should valsi-artifact-minor-mode)
             (should (eq (eq valsi--interaction-state 'browse)
                         (and valsi-browse-mode t)))
             (should (eq (and valsi-browse-mode t) (and buffer-read-only t)))
             (valsi-enter-browse)
             (revert-buffer t t)
             (should (eq valsi--interaction-state 'browse))
             (should valsi-browse-mode)
             (should buffer-read-only))))
      (valsi-global-mode (if global 1 -1)))))

;;;; #73: the header line is restored on disable

(ert-deftest valsi-core-test-header-line-restored ()
  "Disabling the minor mode restores the previous header line."
  (valsi-init)
  (with-temp-buffer
    (insert "# P\n\n- [ ] T001 x\n")
    (setq-local header-line-format "MY HEADER")
    (valsi-artifact-minor-mode 1)
    (should (equal header-line-format valsi--header-line-format))
    (valsi-artifact-minor-mode 1)
    (valsi-artifact-minor-mode -1)
    (should (equal header-line-format "MY HEADER")))
  (with-temp-buffer
    (insert "# P\n")
    (valsi-artifact-minor-mode 1)
    (valsi-artifact-minor-mode -1)
    (should-not (local-variable-p 'header-line-format))))

;;;; #74: font-lock follows the resolved grammar

(defun valsi-core-test--grammar-keywords ()
  "Return the keywords the current buffer's grammar declares."
  (let ((kw (plist-get (valsi-registry-get valsi--grammar) :font-lock)))
    (if (functionp kw) (funcall kw (current-buffer)) kw)))

(ert-deftest valsi-core-test-font-lock-follows-grammar-change ()
  "Re-detection after an edit installs the new grammar's keywords."
  (valsi-init)
  (valsi-core-test--with-file
   "notes.md" "# Notes\n\nplain text\n"
   (lambda ()
     (valsi-artifact-minor-mode 1)
     (let ((before valsi--grammar))
       (let ((inhibit-read-only t))
         (goto-char (point-max))
         (insert "\n- [ ] T001 a\n- [ ] T002 b\n"))
       (valsi-refresh)
       (should (eq valsi--grammar 'plan))
       (should-not (eq before 'plan))
       (should (equal valsi-view--installed-keywords
                      (valsi-core-test--grammar-keywords)))))))

(ert-deftest valsi-core-test-font-lock-follows-grammar-reload ()
  "Re-registering a grammar refreshes keywords in its open buffers."
  (valsi-init)
  (let* ((spec (valsi-registry-get 'plan))
         (keywords '(("T001" . 'bold))))
    (unwind-protect
        (valsi-core-test--with-file
         "PLAN.md" valsi-core-test--plan
         (lambda ()
           (valsi-artifact-minor-mode 1)
           (should (eq valsi--grammar 'plan))
           (valsi-registry-register
            (plist-put (copy-sequence spec) :font-lock keywords))
           (should (equal valsi-view--installed-keywords keywords))))
      (valsi-registry-register spec))))

(provide 'valsi-core-test)
;;; valsi-core-test.el ends here

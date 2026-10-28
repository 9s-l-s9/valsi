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

(provide 'valsi-core-test)
;;; valsi-core-test.el ends here

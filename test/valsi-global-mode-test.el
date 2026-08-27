;;; valsi-global-mode-test.el --- Tests for auto-enable and detection -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `valsi-global-mode' runs grammar detection on every markdown buffer, so
;; the text it hands to `valsi-registry-detect' must be cheap to produce and
;; still carry the head-of-file signals the grammars score on.

;;; Code:

(require 'ert)
(require 'valsi)

(defun valsi-global-mode-test--with-file (name content fn)
  "Visit a temporary file NAME holding CONTENT and call FN in its buffer."
  (let* ((dir (make-temp-file "valsi-gm" t))
         (file (expand-file-name name dir)))
    (unwind-protect
        (progn
          (with-temp-file file (insert content))
          (with-current-buffer (find-file-noselect file)
            (unwind-protect (funcall fn)
              (set-buffer-modified-p nil)
              (kill-buffer))))
      (delete-directory dir t))))

(ert-deftest valsi-global-mode-test-detection-text-respects-limit ()
  "Detection reads at most `valsi-detect-head-limit' characters."
  (valsi-init)
  (valsi-global-mode-test--with-file
   "notes.md" (make-string 1000 ?x)
   (lambda ()
     (let ((valsi-detect-head-limit 100))
       (should (= 100 (length (valsi--detection-text)))))
     (let ((valsi-detect-head-limit nil))
       (should (= 1000 (length (valsi--detection-text)))))
     (narrow-to-region 10 20)
     (let ((valsi-detect-head-limit 100))
       (should (= 100 (length (valsi--detection-text))))))))

(ert-deftest valsi-global-mode-test-enables-on-plan-head ()
  "A plan is still detected when only its head is read."
  (valsi-init)
  (valsi-global-mode-test--with-file
   "PLAN.md"
   (concat "# Plan\n\n- [ ] 1. First task\n  - _Requirements: 1.1_\n"
           (make-string 5000 ?\n) "trailing prose\n")
   (lambda ()
     (let ((valsi-detect-head-limit 64))
       (valsi-artifact-minor-mode -1)
       (valsi--maybe-enable)
       (should valsi-artifact-minor-mode)))))

(ert-deftest valsi-global-mode-test-skips-non-markdown ()
  "Non-markdown files never reach grammar detection."
  (valsi-init)
  (valsi-global-mode-test--with-file
   "PLAN.txt" "- [ ] 1. looks like a plan\n"
   (lambda ()
     (valsi-artifact-minor-mode -1)
     (valsi--maybe-enable)
     (should-not valsi-artifact-minor-mode))))

(provide 'valsi-global-mode-test)
;;; valsi-global-mode-test.el ends here

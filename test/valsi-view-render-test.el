;;; valsi-view-render-test.el --- View rendering and navigation regressions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Regressions for re-rendering preserved views and visiting source rows.

;;; Code:

(require 'ert)
(require 'valsi)

(defun valsi-view-render-test--fill (&optional offset)
  "Insert fifty identified rows, preceded by OFFSET plain lines."
  (erase-buffer)
  (dotimes (_ (or offset 0)) (insert "header\n"))
  (dotimes (i 50)
    (insert (propertize (format "row %d\n" i)
                        'valsi-row-id (format "r%d" i)))))

(ert-deftest valsi-view-render-preserves-unselected-window-point ()
  "Re-rendering keeps each window's point on its own semantic row (#44)."
  (let ((buffer (generate-new-buffer " *valsi-view-render*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (with-current-buffer buffer (valsi-view-render-test--fill))
          (let ((other (split-window)))
            (set-window-buffer other buffer)
            (set-window-point
             other (with-current-buffer buffer
                     (save-excursion (goto-char (point-min))
                                     (forward-line 30)
                                     (point))))
            (with-current-buffer buffer
              (goto-char (point-min))
              (forward-line 5)
              (valsi-view-preserving-render
               (lambda () (valsi-view-render-test--fill 2)))
              (should (equal "r5" (get-text-property (point) 'valsi-row-id))))
            (should (equal "r30" (get-text-property (window-point other)
                                                    'valsi-row-id buffer)))
            (should (= (window-point other)
                       (with-current-buffer buffer
                         (save-excursion
                           (goto-char (point-min))
                           (forward-line 32)
                           (point)))))))
      (kill-buffer buffer))))

(provide 'valsi-view-render-test)

;;; valsi-view-render-test.el ends here

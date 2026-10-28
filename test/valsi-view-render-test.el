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

;; Outline rows with identical labels.

(ert-deftest valsi-view-outline-duplicate-labels-keep-their-row ()
  "Refreshing an outline keeps point on the same duplicate-label row (#45)."
  (valsi-init)
  (let ((tree (valsi-overview-parse
               "# Doc\n\n## Example\n\n## Example\n\n## Example\n")))
    (with-temp-buffer
      (let ((render (lambda ()
                      (erase-buffer)
                      (valsi-view-insert-outline tree (current-buffer) 3))))
        (funcall render)
        (goto-char (point-min))
        (forward-line 2)
        (valsi-view-preserving-render render)
        (should (= 3 (line-number-at-pos)))
        (should (= 3 (length (delete-dups
                              (mapcar (lambda (line)
                                        (goto-char (point-min))
                                        (forward-line line)
                                        (get-text-property (point)
                                                           'valsi-row-id))
                                      '(0 1 2))))))))))

;; Visiting source positions keeps a narrowing that contains them.

(defun valsi-view-render-test--visit (source position)
  "Visit POSITION in SOURCE through a one-row source table."
  (let ((table (generate-new-buffer " *valsi-view-table*")))
    (unwind-protect
        (with-current-buffer table
          (tabulated-list-mode)
          (setq tabulated-list-format [("Row" 10 nil)]
                tabulated-list-entries `((,position ["row"]))
                valsi-view--source-buffer source)
          (tabulated-list-init-header)
          (tabulated-list-print)
          (goto-char (point-min))
          (valsi-view-visit-source))
      (kill-buffer table))))

(ert-deftest valsi-view-visit-source-keeps-containing-narrowing ()
  "Visiting a row widens the source only for positions outside (#58)."
  (let ((source (generate-new-buffer " *valsi-view-narrowed*")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer source
            (insert "# T\n\n## A\n\n## B\n")
            (narrow-to-region (point-min) 8))
          (valsi-view-render-test--visit source 1)
          (with-current-buffer source
            (should (buffer-narrowed-p))
            (should (= 1 (point))))
          (valsi-view-render-test--visit source 12)
          (with-current-buffer source
            (should-not (buffer-narrowed-p))
            (should (= 12 (point)))))
      (kill-buffer source))))

(ert-deftest valsi-view-outline-jump-widens-only-outside-narrowing ()
  "An outline jump outside the narrowing widens instead of clamping (#58)."
  (let ((source (generate-new-buffer " *valsi-view-narrowed*")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer source
            (insert "# T\n\n## A\n\n## B\n")
            (narrow-to-region (point-min) 8))
          (with-temp-buffer
            (insert-text-button "T" 'valsi-source source 'valsi-pos 1
                                'action #'valsi-view--outline-jump)
            (valsi-view--outline-jump (button-at (point-min))))
          (with-current-buffer source
            (should (buffer-narrowed-p))
            (should (= 1 (point))))
          (with-temp-buffer
            (insert-text-button "B" 'valsi-source source 'valsi-pos 12
                                'action #'valsi-view--outline-jump)
            (valsi-view--outline-jump (button-at (point-min))))
          (with-current-buffer source
            (should-not (buffer-narrowed-p))
            (should (= 12 (point)))))
      (kill-buffer source))))

(provide 'valsi-view-render-test)

;;; valsi-view-render-test.el ends here

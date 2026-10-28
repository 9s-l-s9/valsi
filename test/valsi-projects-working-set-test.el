;;; valsi-projects-working-set-test.el --- Projects quit and removal tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Regression tests for leaving Projects after its origin buffers died and
;; for removing the project the overview was opened from.

;;; Code:

(require 'ert)
(require 'valsi-projects-test)

(ert-deftest valsi-projects-quit-with-killed-origin-falls-back-to-hub ()
  "Quitting after the origin buffer was killed shows the origin hub (#54)."
  (valsi-projects-test--with-projects
    (let ((source (find-file-noselect fa)))
      (switch-to-buffer source)
      (delete-other-windows)
      (valsi-projects)
      (kill-buffer source)
      (with-current-buffer "*Valsi Projects*" (valsi-projects-quit))
      (should-not (get-buffer-window "*Valsi Projects*"))
      (with-current-buffer (window-buffer (selected-window))
        (should (derived-mode-p 'valsi-app-mode))
        (should (equal a valsi-app--root))))))

;; Emacs 29 has no `window-restore-killed-buffer-windows' and its
;; `window-state-put' signals for killed buffers (#86).  These tests force
;; the Emacs 29 restore path, so it is exercised on every version.

(defmacro valsi-projects-test--with-emacs-29-restore (&rest body)
  "Run BODY restoring layouts the way Valsi does on Emacs 29."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'valsi-projects--state-put)
              #'valsi-projects--state-put-without-killed))
     ,@body))

(ert-deftest valsi-projects-state-put-drops-killed-buffer-windows ()
  "A killed buffer's window is deleted; the rest of the layout survives (#86)."
  (save-window-excursion
    (let ((kept (generate-new-buffer "valsi-kept"))
          (killed (generate-new-buffer "valsi-killed"))
          (other (generate-new-buffer "valsi-other")))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer kept)
            (set-window-buffer (split-window-right) killed)
            (let ((state (window-state-get (frame-root-window))))
              (delete-other-windows)
              (switch-to-buffer other)
              (kill-buffer killed)
              (valsi-projects--state-put-without-killed state)
              (should (equal (list kept)
                             (mapcar #'window-buffer (window-list nil 'nomini))))
              (should-not (seq-find (lambda (buffer)
                                      (string-prefix-p " *valsi-killed-window"
                                                       (buffer-name buffer)))
                                    (buffer-list)))))
        (mapc (lambda (buffer) (when (buffer-live-p buffer) (kill-buffer buffer)))
              (list kept killed other))))))

(ert-deftest valsi-projects-state-put-keeps-sole-killed-buffer-window ()
  "The frame's only window survives with another buffer when its buffer died (#86)."
  (save-window-excursion
    (let ((killed (generate-new-buffer "valsi-killed"))
          (other (generate-new-buffer "valsi-other")))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer killed)
            (let ((state (window-state-get (frame-root-window))))
              (switch-to-buffer other)
              (kill-buffer killed)
              (valsi-projects--state-put-without-killed state)
              (should (one-window-p))
              (should (buffer-live-p (window-buffer (selected-window))))
              (should-not (string-prefix-p
                           " " (buffer-name (window-buffer (selected-window)))))))
        (mapc (lambda (buffer) (when (buffer-live-p buffer) (kill-buffer buffer)))
              (list killed other))))))

(ert-deftest valsi-projects-quit-with-killed-origin-on-emacs-29-path ()
  "Quitting after the origin was killed falls back to the hub on Emacs 29 (#86)."
  (valsi-projects-test--with-emacs-29-restore
    (valsi-projects-test--with-projects
      (let ((source (find-file-noselect fa)))
        (switch-to-buffer source)
        (delete-other-windows)
        (valsi-projects)
        (kill-buffer source)
        (with-current-buffer "*Valsi Projects*" (valsi-projects-quit))
        (should-not (get-buffer-window "*Valsi Projects*"))
        (with-current-buffer (window-buffer (selected-window))
          (should (derived-mode-p 'valsi-app-mode))
          (should (equal a valsi-app--root)))))))

(defun valsi-projects-test--switch-back-after-killing-secondary ()
  "Return window buffer names after resuming a layout with a killed window."
  (valsi-projects-test--with-projects
    (let ((extra (expand-file-name "NOTES.md" a))
          (source (find-file-noselect fa)))
      (with-temp-file extra (insert "# Notes\n"))
      (valsi-project-switch a)
      (switch-to-buffer source)
      (delete-other-windows)
      (set-window-buffer (split-window-right) (find-file-noselect extra))
      (valsi-project-switch b)
      (kill-buffer (get-file-buffer extra))
      (valsi-project-switch a)
      (mapcar (lambda (window) (buffer-name (window-buffer window)))
              (window-list nil 'nomini)))))

(ert-deftest valsi-project-switch-keeps-layout-without-killed-window ()
  "Resuming drops only the killed buffer's window (#86)."
  (should (equal '("PLAN.md") (valsi-projects-test--switch-back-after-killing-secondary)))
  (valsi-projects-test--with-emacs-29-restore
    (should (equal '("PLAN.md")
                   (valsi-projects-test--switch-back-after-killing-secondary)))))

(ert-deftest valsi-projects-removed-current-project-stays-removed ()
  "Reopening Projects from a removed project does not re-add it (#56)."
  (valsi-projects-test--with-projects
    (let ((valsi-projects--removed nil))
      (switch-to-buffer (find-file-noselect fa))
      (delete-other-windows)
      (valsi-projects)
      (should (equal (list a) (valsi-project-roots)))
      (with-current-buffer "*Valsi Projects*"
        (valsi-projects-test--row a)
        (valsi-projects-remove))
      (should-not (valsi-project-roots))
      (with-current-buffer "*Valsi Projects*" (valsi-projects-quit))
      (set-buffer (window-buffer (selected-window)))
      (valsi-projects)
      (should-not (valsi-project-roots))
      ;; Opening it explicitly makes it a working project again.
      (valsi-project-switch a)
      (should (equal (list a) (valsi-project-roots)))
      (valsi-projects)
      (should (equal (list a) (valsi-project-roots))))))

(ert-deftest valsi-projects-dedicated-window-stays-with-its-project ()
  "A dedicated selected window never leaks into Projects or a new project (#89)."
  (valsi-projects-test--with-projects
    (let ((names (lambda ()
                   (mapcar (lambda (window) (buffer-name (window-buffer window)))
                           (window-list nil 'nomini)))))
      (valsi-project-switch a)
      (delete-other-windows)
      (switch-to-buffer (find-file-noselect fa))
      (set-window-dedicated-p (selected-window) t)
      (valsi-projects)
      (should (equal '("*Valsi Projects*") (funcall names)))
      (with-current-buffer "*Valsi Projects*" (valsi-projects-quit))
      ;; Leaving Projects restores the dedicated window unchanged.
      (should (equal '("PLAN.md") (funcall names)))
      (should (window-dedicated-p (selected-window)))
      (valsi-project-switch b)
      (should (equal (list (buffer-name (valsi-app--buffer b nil))) (funcall names)))
      (valsi-project-switch a)
      (should (window-dedicated-p (get-buffer-window (get-file-buffer fa))))
      (valsi-project-switch b)
      (should (equal (list (buffer-name (valsi-app--buffer b nil))) (funcall names))))))

;; Batch Emacs cannot create a minibuffer-only frame, so these stub the
;; frame primitives with symbols standing in for frames and windows (#88).

(defmacro valsi-projects-test--with-fake-frames (spec &rest body)
  "Run BODY with fake frames from SPEC.
SPEC is a plist with :frames (FRAME MINIBUFFER-PARAMETER MINIBUFFER-FRAME)
entries, :selected-window, and :last-frame."
  (declare (indent 1))
  `(let* ((spec ,spec)
          (frames (plist-get spec :frames)))
     (cl-letf (((symbol-function 'frame-parameter)
                (lambda (frame parameter)
                  (when (eq parameter 'minibuffer) (nth 1 (assq frame frames)))))
               ((symbol-function 'frame-live-p) (lambda (frame) (and (assq frame frames) t)))
               ((symbol-function 'frame-list) (lambda () (mapcar #'car frames)))
               ((symbol-function 'minibuffer-selected-window)
                (lambda () (plist-get spec :selected-window)))
               ((symbol-function 'last-nonminibuffer-frame)
                (lambda () (plist-get spec :last-frame)))
               ((symbol-function 'minibuffer-window)
                (lambda (frame) (list 'minibuffer (nth 2 (assq frame frames)))))
               ((symbol-function 'window-frame)
                (lambda (window)
                  (if (eq (car-safe window) 'minibuffer) (cadr window) window))))
       ,@body)))

(ert-deftest valsi-projects-working-frame-keeps-ordinary-frames ()
  "A frame with ordinary windows manages its own layouts (#88)."
  (should (eq (selected-frame) (valsi-projects--working-frame)))
  (valsi-projects-test--with-fake-frames
      '(:frames ((work nil mb) (mb only mb)) :last-frame work)
    (should (eq 'work (valsi-projects--working-frame 'work)))))

(ert-deftest valsi-projects-working-frame-resolves-minibuffer-only-frames ()
  "Commands invoked in a minibuffer-only frame manage a working frame (#88)."
  (let ((frames '((one nil mb) (two nil mb) (other t other) (mb only mb))))
    ;; The frame the active minibuffer was entered from wins.
    (valsi-projects-test--with-fake-frames
        `(:frames ,frames :selected-window two :last-frame one)
      (should (eq 'two (valsi-projects--working-frame 'mb))))
    ;; Otherwise the last frame with ordinary windows.
    (valsi-projects-test--with-fake-frames
        `(:frames ,frames :last-frame one)
      (should (eq 'one (valsi-projects--working-frame 'mb))))
    (valsi-projects-test--with-fake-frames
        `(:frames ,frames :last-frame mb)
      ;; Then a frame that uses this minibuffer frame, never itself.
      (should (memq (valsi-projects--working-frame 'mb) '(one two))))
    (valsi-projects-test--with-fake-frames
        '(:frames ((other t other) (mb only mb)))
      (should (eq 'other (valsi-projects--working-frame 'mb))))
    (valsi-projects-test--with-fake-frames '(:frames ((mb only mb)))
      (should (eq 'mb (valsi-projects--working-frame 'mb))))))

(provide 'valsi-projects-working-set-test)
;;; valsi-projects-working-set-test.el ends here

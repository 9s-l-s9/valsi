;;; valsi-benchmark.el --- Repeatable interaction measurements -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run with make benchmark.  Reports wall time including garbage collection.
;; Tests assert correctness and work counts separately; these are observations,
;; not machine-dependent pass/fail thresholds.  No agent process is started.

;;; Code:

(require 'valsi)
(require 'benchmark)

(defun valsi-benchmark--plan (count)
  "Return a COUNT-task plan with a linear dependency chain."
  (concat "# Plan\n"
          (mapconcat
           (lambda (id)
             (format "- [ ] T%03d Task%s\n" id
                     (if (= id 1) ""
                       (format " (depends on T%03d)" (1- id)))))
           (number-sequence 1 count) "")))

(defun valsi-benchmark--measure (label count function)
  "Print mean milliseconds for COUNT calls of FUNCTION under LABEL."
  (garbage-collect)
  (condition-case error
      (let ((timing (benchmark-call function count)))
        (princ (format "%-36s %9.3f ms/op  (%d runs, %d GCs)\n"
                       label (* 1000 (/ (car timing) count)) count (cadr timing))))
    (error (princ (format "%-36s ERROR: %s\n" label (error-message-string error))))))

(defun valsi-benchmark--chunked-scan (root)
  "Report initial display, longest work turn, and completion time for ROOT."
  (valsi-app-live-refresh-reset root)
  (let ((advance (symbol-function 'valsi-app-live-refresh--continue))
        started turns hub)
    (unwind-protect
        (cl-letf (((symbol-function 'valsi-app-live-refresh--continue)
                   (lambda (&rest args)
                     (let ((start (float-time)))
                       (prog1 (apply advance args)
                         (push (- (float-time) start) turns))))))
          (setq started (float-time)
                hub (valsi-app--buffer root nil))
          (princ (format "%-36s %9.3f ms\n" "Cold hub initial display"
                         (* 1000 (- (float-time) started))))
          (let ((project (valsi-app-live-refresh--project root)))
            (while (and (valsi-app-live-refresh--project-timer project)
                        (< (- (float-time) started) 30))
              (accept-process-output nil 0.01))
            (when (or (valsi-app-live-refresh--project-timer project)
                      (valsi-app-live-refresh--project-status project))
              (error "Chunked scan did not finish: %s"
                     (valsi-app-live-refresh--project-status project))))
          (princ (format "%-36s %9.3f ms  (%d turns)\n" "Cold scan longest work turn"
                         (* 1000 (apply #'max turns)) (length turns)))
          (princ (format "%-36s %9.3f ms\n" "Cold scan total incl. yields"
                         (* 1000 (- (float-time) started)))))
      (when (buffer-live-p hub) (kill-buffer hub))
      (valsi-app-live-refresh-reset root))))

(valsi-init)
;; Exclude benchmark.el's first-call loading from the first measurement.
(benchmark-call #'ignore)
(princ (format "Emacs %s; project %s\n" emacs-version default-directory))
(dolist (size '(2000 8000 16000))
  (let ((content (valsi-benchmark--plan size)))
    (valsi-benchmark--measure (format "Parse flat plan (%d tasks)" size) 3
                              (lambda () (valsi-plan-parse content)))))
(dolist (size '(100 300 600))
  (let ((tree (valsi-plan-parse (valsi-benchmark--plan size))))
    (valsi-benchmark--measure (format "Lint dependency chain (%d tasks)" size)
                              1 (lambda () (valsi-plan--lint-collect tree)))))
(let ((tree (valsi-plan-parse
             (mapconcat (lambda (n) (format "%s- [x] Nested task\n"
                                            (make-string (* n 2) ?\s)))
                        (number-sequence 0 15) ""))))
  (valsi-benchmark--measure "Lint completed hierarchy (depth 16)" 3
                            (lambda () (valsi-plan--lint-collect tree))))
(let ((root default-directory)
      hub sidebar)
  (unwind-protect
      (progn
        ;; The user command resolves the project before opening its view.
        ;; Report that one-time backend setup separately from artifact work.
        (valsi-benchmark--measure "Project backend first lookup" 1
                                  (lambda () (project-current nil root)))
        (valsi-benchmark--chunked-scan root)
        (valsi-benchmark--measure "Project scan, cold" 1
                                  (lambda () (valsi-app--scan root)))
        (valsi-benchmark--measure "Project scan, unchanged" 10
                                  (lambda () (valsi-app--scan root)))
        (setq hub (valsi-app--buffer root nil))
        (valsi-benchmark--measure "Return to project hub" 10
                                  (lambda () (valsi-app--buffer root nil)))
        (valsi-benchmark--measure "Cross-artifact graph" 3 #'valsi-graph--entries)
        (valsi-benchmark--measure "Plan dashboard" 3 #'valsi-plan--dashboard-entries)
        (valsi-benchmark--measure "Instruction dashboard" 3 #'valsi-instruction--dashboard-entries)
        (with-temp-buffer
          (insert (valsi-benchmark--plan 2000))
          (setq buffer-file-name (expand-file-name "benchmark/PLAN.md" root))
          (valsi-benchmark--measure "Enable artifact (2000 tasks)" 1
                                    (lambda () (valsi-artifact-minor-mode 1)))
          (valsi-benchmark--measure "Refresh artifact (2000 tasks)" 3 #'valsi-refresh)
          (goto-char (point-min))
          (forward-line 1000)
          (valsi-benchmark--measure "Context lookup (2000 tasks)" 100
                                    (lambda () (valsi-app-context-signature (current-buffer))))
          (valsi-benchmark--measure "Open contextual sidebar" 10
                                    (lambda () (setq sidebar
                                                     (valsi-app--buffer root t (current-buffer)))))
          (valsi-enter-insert)
          (valsi-benchmark--measure "Type character (2000 tasks)" 100
                                    (lambda () (insert "x")))
          (valsi-artifact-minor-mode -1)))
    (when (buffer-live-p hub) (kill-buffer hub))
    (when (buffer-live-p sidebar) (kill-buffer sidebar))
    (valsi-app-live-refresh-reset root)))

;;; valsi-benchmark.el ends here

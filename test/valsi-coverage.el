;;; valsi-coverage.el --- Optional batch execution coverage -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Edebug supplies the same instrumentation used by built-in testcover.
;; This runner records execution, without testcover's value-variation checks:
;; immutable results and circular node trees need no special annotations.
;; Reports count evaluation points, not branches or physical source lines.

;;; Code:

(require 'cl-lib)
(require 'edebug)
(require 'ert)
(require 'json)
(require 'subr-x)

(defvar valsi-coverage--counts nil "Hit vector for the current definition.")
(defvar valsi-coverage--definitions nil "Definitions instrumented in one file.")

(defun valsi-coverage--definition (symbol)
  "Register SYMBOL with the coverage execution behavior."
  (put symbol 'edebug-behavior 'valsi-coverage)
  (push symbol valsi-coverage--definitions))

(defun valsi-coverage--enter (symbol _arguments body)
  "Evaluate BODY with SYMBOL's hit vector, ignoring _ARGUMENTS."
  (let ((valsi-coverage--counts (get symbol 'edebug-freq-count)))
    (funcall body)))

(defun valsi-coverage--before (index)
  "Record entry at INDEX and return it for Edebug's after hook."
  (aset valsi-coverage--counts index 1)
  index)

(defun valsi-coverage--after (_before index value)
  "Record completion at INDEX and return VALUE, ignoring _BEFORE."
  (aset valsi-coverage--counts index 1)
  value)

(defun valsi-coverage--instrument (file)
  "Instrument FILE and return its definitions without compiling on disk."
  (with-current-buffer (find-file-noselect file)
    (let ((edebug-all-defs t)
          (edebug-new-definition-function #'valsi-coverage--definition)
          (edebug-after-instrumentation-function #'identity)
          valsi-coverage--definitions)
      (eval-buffer)
      (nreverse valsi-coverage--definitions))))

(defun valsi-coverage--function-report (symbol)
  "Return execution counts and missed source lines for SYMBOL."
  (let* ((data (get symbol 'edebug))
         (marker (car data))
         (offsets (nth 2 data))
         (counts (get symbol 'edebug-freq-count))
         (hits 0) missed)
    (dotimes (index (length counts))
      (if (> (aref counts index) 0)
          (cl-incf hits)
        (with-current-buffer (marker-buffer marker)
          (push (line-number-at-pos (+ marker (aref offsets index))) missed))))
    (list :name (symbol-name symbol) :hit hits :total (length counts)
          :missedLines (vconcat (sort (delete-dups missed) #'<)))))

(defun valsi-coverage-batch ()
  "Run ERT with optional Edebug coverage and write a JSON report.
COVERAGE_FILES selects space-separated source files, COVERAGE_TESTS selects
test files, and COVERAGE_REPORT names the report, defaulting to coverage.json.
Coverage percentages are diagnostic; only unexpected ERT results fail the run."
  (let* ((root default-directory)
         (files (split-string (or (getenv "COVERAGE_FILES") "") nil t))
         (tests (split-string (or (getenv "COVERAGE_TESTS") "") nil t))
         (report (expand-file-name (or (getenv "COVERAGE_REPORT") "coverage.json")))
         (edebug-behavior-alist
          (cons '(valsi-coverage valsi-coverage--enter
                                 valsi-coverage--before valsi-coverage--after)
                edebug-behavior-alist))
         instrumented rows stats)
    (unless files (error "COVERAGE_FILES must select at least one source file"))
    ;; Load dependencies and test macros before instrumenting implementation.
    (dolist (file tests) (load (expand-file-name file) nil t t))
    (dolist (file files)
      (push (cons file (valsi-coverage--instrument file)) instrumented))
    (setq stats (ert-run-tests-batch t))
    (dolist (entry (nreverse instrumented))
      (let* ((functions (mapcar #'valsi-coverage--function-report (cdr entry)))
             (hit (apply #'+ (mapcar (lambda (fn) (plist-get fn :hit)) functions)))
             (total (apply #'+ (mapcar (lambda (fn) (plist-get fn :total)) functions))))
        (princ (format "%s: %d/%d evaluation points (%.1f%%)\n"
                       (car entry) hit total (if (zerop total) 0.0 (* 100.0 (/ (float hit) total)))))
        (push (list :file (car entry) :hit hit :total total
                    :functions (vconcat functions)) rows)))
    (with-temp-file report
      (insert (json-serialize
               (list :metric "edebug evaluation points (not branch coverage)"
                     :root root :files (vconcat (nreverse rows)))))
      (insert "\n"))
    (princ (format "Coverage report: %s\n" report))
    (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1))))

(provide 'valsi-coverage)
;;; valsi-coverage.el ends here

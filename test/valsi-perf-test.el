;;; valsi-perf-test.el --- Perf/scale tests for Valsi -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; v1.0 hardening: parse + serialize at scale.  The reparse
;; model is cache + full reparse on change (the client caches `valsi--tree' and
;; invalidates it on edit), so the load-bearing perf property is that a full
;; parse of a large plan is fast and correct, and that the edit->reparse loop
;; stays cheap.  Time budgets are deliberately generous (CI headroom); the point
;; is to catch pathological blow-ups, and to print elapsed times as a profiling
;; record.

;;; Code:

(require 'ert)
(require 'valsi-plan)
(require 'valsi-node)

(defconst valsi-perf--phases 20 "Phase count in the synthetic large plan.")
(defconst valsi-perf--per-phase 100 "Tasks per phase in the synthetic plan.")

(defun valsi-perf--big-plan ()
  "Return a large synthetic plan string (PHASES * PER-PHASE tasks)."
  (let ((out (list "# Big plan\n\n")) (n 0))
    (dotimes (p valsi-perf--phases)
      (push (format "## Sprint %d: phase %d\n\n" (1+ p) (1+ p)) out)
      (dotimes (i valsi-perf--per-phase)
        (setq n (1+ n))
        (push (format "- [ ] T%03d [P] task %d (depends on T%03d)\n"
                      n n (max 1 (1- n)))
              out)))
    (apply #'concat (nreverse out))))

(defmacro valsi-perf--timed (label &rest body)
  "Run BODY, print elapsed seconds under LABEL, and return the elapsed time."
  (declare (indent 1))
  `(let ((start (float-time)))
     ,@body
     (let ((elapsed (- (float-time) start)))
       (message "  [perf] %s: %.3fs" ,label elapsed)
       elapsed)))

(ert-deftest valsi-test-perf-parse-large ()
  "A large plan parses correctly and quickly."
  (let* ((content (valsi-perf--big-plan))
         (want (* valsi-perf--phases valsi-perf--per-phase))
         root elapsed)
    (setq elapsed (valsi-perf--timed "parse 2000-task plan"
                    (setq root (valsi-plan-parse content))))
    (should (= want (length (valsi-node-of-type root 'task))))
    (should (< elapsed 5.0))))

(ert-deftest valsi-test-perf-serialize-large ()
  "Serializing a large tree to the wire plist preserves every node."
  (let* ((root (valsi-plan-parse (valsi-perf--big-plan)))
         (count 0) pl)
    (valsi-node-walk root (lambda (_n _d) (setq count (1+ count))))
    (valsi-perf--timed "to-plist + from-plist 2000-task plan"
      (setq pl (valsi-node-to-plist root)))
    (let ((rehydrated 0))
      (valsi-node-walk (valsi-node-from-plist pl)
                      (lambda (_n _d) (setq rehydrated (1+ rehydrated))))
      (should (= count rehydrated)))))

(ert-deftest valsi-test-perf-reparse-loop ()
  "The edit->reparse loop (full reparse each time) stays cheap."
  (let ((content (valsi-perf--big-plan))
        (iterations 20)
        (elapsed 0.0))
    (setq elapsed
          (valsi-perf--timed (format "%d full reparses" iterations)
            (dotimes (_ iterations) (valsi-plan-parse content))))
    (should (< elapsed 15.0))))

;;;; Regexp work per line
;;
;; Wall-clock budgets above are generous, so a constant-factor slowdown
;; slips through them.  These guards count regexp calls instead, which is
;; deterministic: every per-line recognizer that runs its regexp on lines
;; it cannot match costs a full match attempt, and once a parse uses more
;; distinct regexps than Emacs's compiled-pattern cache holds (20 entries,
;; REGEXP_CACHE_SIZE in search.c) each attempt also recompiles its pattern.
;; The fence, closing-hash and leading-token regexps once ran unguarded on
;; every line (about 8 calls per line, 24 distinct patterns), a slowdown
;; no time budget here noticed.

(defconst valsi-perf--regexp-cache-size 20
  "Entries in Emacs's compiled-regexp cache (REGEXP_CACHE_SIZE).")

(defconst valsi-perf--fixture-dir
  (expand-file-name "fixtures"
                    (file-name-directory
                     (or load-file-name buffer-file-name default-directory)))
  "Directory of the corpus fixtures.")

(defun valsi-perf--fixture-plan ()
  "Return the plan fixtures concatenated: every dialect, fences included."
  (mapconcat (lambda (name)
               (with-temp-buffer
                 (insert-file-contents
                  (expand-file-name name valsi-perf--fixture-dir))
                 (buffer-string)))
             '("speckit-tasks-template.md" "wild-speckit-goataka-tasks.md"
               "kiro-tasks-example.md" "wild-kiro-awslabs-tasks.md"
               "wild-superpowers-caasi-plan.md" "wild-gsd-triggarr-plan.md"
               "speckit-real-fragment.md")
             "\n"))

(defun valsi-perf--count-regexps (function)
  "Call FUNCTION; return (CALLS . DISTINCT) for the regexps it matched."
  (let* ((seen (make-hash-table :test #'equal))
         (calls 0)
         (note (lambda (regexp &rest _)
                 (setq calls (1+ calls))
                 (puthash regexp t seen))))
    (advice-add 'string-match :before note)
    (unwind-protect (funcall function)
      (advice-remove 'string-match note))
    (cons calls (hash-table-count seen))))

(ert-deftest valsi-test-perf-regexp-working-set ()
  "A plan parse fits the regexp cache and guards its per-line regexps."
  (let* ((content (valsi-perf--fixture-plan))
         (lines (length (split-string content "\n")))
         (count (valsi-perf--count-regexps
                 (lambda () (valsi-plan-parse content)))))
    (message "  [perf] plan parse: %d lines, %d regexp calls, %d distinct"
             lines (car count) (cdr count))
    ;; Advice cannot see calls from natively compiled code.
    (skip-unless (> (car count) 0))
    (should (<= (cdr count) valsi-perf--regexp-cache-size))
    ;; Unguarded recognizers made this about 8 calls per line.
    (should (< (car count) (* 4 lines)))))

(ert-deftest valsi-test-perf-prose-line-regexps ()
  "A prose line costs no recognizer regexp in the line split or plan parse."
  (let* ((content (mapconcat (lambda (n) (format "Plain prose line %d." n))
                             (number-sequence 1 200) "\n"))
         (count (valsi-perf--count-regexps
                 (lambda () (valsi-plan-parse content)))))
    ;; Only dialect detection may run, a handful of times per document.
    (should (< (car count) 10))))

(provide 'valsi-perf-test)
;;; valsi-perf-test.el ends here

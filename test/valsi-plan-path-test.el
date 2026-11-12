;;; valsi-plan-path-test.el --- Nested plan reference tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Exercise shared path resolution through the commands that consume it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-plan-agent)

(defmacro valsi-plan-path-test--with-project (directory &rest body)
  "Run BODY in a plan below DIRECTORY in a temporary project."
  (declare (indent 1) (debug t))
  `(let* ((project-dir (file-name-as-directory (make-temp-file "valsi-path-" t)))
          (plan-dir (expand-file-name ,directory project-dir))
          (plan-file (expand-file-name "tasks.md" plan-dir))
          (target (expand-file-name "src/code.el" project-dir)))
     (unwind-protect
         (progn
           (make-directory plan-dir t)
           (make-directory (file-name-directory target) t)
           (with-temp-file target (insert "one\ntwo\nthree\nfour\n"))
           (with-temp-file plan-file (insert "- [x] T001 Check `src/code.el:3`\n"))
           (with-temp-buffer
             (insert-file-contents plan-file)
             (setq buffer-file-name plan-file
                   default-directory (file-name-as-directory plan-dir)
                   valsi-project-root project-dir)
             (goto-char (point-min))
             ,@body))
       (delete-directory project-dir t))))

(ert-deftest valsi-plan-path-nested-lint-flymake-and-stale ()
  "Spec-kit, Kiro and planning files find targets under the project root."
  (dolist (directory '("specs/001-feature" ".kiro/specs/feature" ".planning"))
    (valsi-plan-path-test--with-project directory
      (let ((root (valsi-plan--buffer-tree)) diagnostics)
        (should-not (valsi-plan--missing-file-findings root))
        (valsi-plan-flymake (lambda (result) (setq diagnostics result)))
        (should-not diagnostics)
        (set-file-times plan-file (seconds-to-time 1000))
        (set-file-times target (seconds-to-time 2000))
        (should (equal '(("T001" . "src/code.el"))
                       (valsi-plan--stale-tasks root plan-file)))))))

(ert-deftest valsi-plan-path-root-precedence-and-local-fallback ()
  "Root wins when both files exist; removing it reveals the plan-local target."
  (valsi-plan-path-test--with-project "specs/001"
    (let* ((local (expand-file-name "src/code.el" plan-dir))
           (directories (valsi-plan--reference-directories)))
      (make-directory (file-name-directory local) t)
      (with-temp-file local (insert "local"))
      (should (equal target (valsi-plan--resolve-pathref "src/code.el:3" directories)))
      (delete-file target)
      (should (equal local (valsi-plan--resolve-pathref "src/code.el:3" directories)))
      (should-not (valsi-plan--missing-file-findings (valsi-plan--buffer-tree)))
      (delete-file local)
      (should (= 1 (length (valsi-plan--missing-file-findings
                           (valsi-plan--buffer-tree)))))
      (should-not (valsi-plan--resolve-pathref "src/code.el:3" directories)))))

(ert-deftest valsi-plan-path-discovers-project-from-plan-directory ()
  "A source without a Valsi association discovers its project through project.el."
  (skip-unless (executable-find "git"))
  (valsi-plan-path-test--with-project "specs/001"
    (let ((default-directory project-dir))
      (should (zerop (call-process "git" nil nil nil "init" "--quiet"))))
    (setq valsi-project-root nil)
    (should (equal (file-truename project-dir)
                   (car (valsi-plan--reference-directories))))
    (should-not (valsi-plan--missing-file-findings (valsi-plan--buffer-tree)))
    ;; Explicit source directories must not reuse an unrelated buffer's root.
    (setq valsi-project-root "/unrelated/")
    (should (equal (file-truename project-dir)
                   (car (valsi-plan--reference-directories plan-dir))))))

(ert-deftest valsi-plan-path-standalone-falls-back-to-file-directory ()
  "Outside a project, the file's directory wins over an unrelated default."
  (valsi-plan-path-test--with-project "specs/001"
    (setq valsi-project-root nil default-directory "/")
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
      (should (equal (list (file-name-as-directory plan-dir))
                     (valsi-plan--reference-directories))))))

(ert-deftest valsi-plan-path-follow-keeps-line-in-target ()
  "Following a reference opens the root-relative file at its line suffix."
  (valsi-plan-path-test--with-project ".kiro/specs/feature"
    (let ((destination (generate-new-buffer " *valsi-path-target*")) visited)
      (unwind-protect
          (save-current-buffer
            (with-current-buffer destination (insert-file-contents target))
            (cl-letf (((symbol-function 'find-file-other-window)
                       (lambda (file &rest _)
                         (setq visited file)
                         (set-buffer destination))))
              (should (valsi-plan--follow-pathref-at-point))
              (should (equal target visited))
              (should (eq destination (current-buffer)))
              (should (= 3 (line-number-at-pos)))))
        (kill-buffer destination)))))

(ert-deftest valsi-plan-path-skip-urls-and-globs ()
  "Non-file references are ignored consistently by navigation and lint."
  (valsi-plan-path-test--with-project "specs/001"
    (erase-buffer)
    (insert "- [x] T001 `https://example.test/a` `src/*.el`\n")
    (goto-char (point-min))
    (should-not (valsi-plan--missing-file-findings (valsi-plan--buffer-tree)))
    (should-not (valsi-plan--follow-pathref-at-point))))

(ert-deftest valsi-plan-path-lint-probes-each-distinct-file-once ()
  "Repeated references, including missing ones, do not multiply disk probes."
  (valsi-plan-path-test--with-project "specs/001"
    (erase-buffer)
    (dotimes (n 10)
      (insert (format "- [x] T%03d `src/code.el` `src/missing.el`\n" n)))
    (let ((probe (symbol-function 'file-exists-p)) calls)
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (file) (push file calls) (funcall probe file))))
        (should (= 10 (length (valsi-plan--missing-file-findings
                              (valsi-plan--buffer-tree))))))
      (should (= 3 (length calls))))))

(ert-deftest valsi-plan-path-remote-flymake-does-no-file-probes ()
  "Automatic remote diagnostics retain structural checks without remote I/O."
  (with-temp-buffer
    (insert "- [x] T001 `src/code.el`\n- [ ] T001 duplicate\n")
    (setq buffer-file-name "/ssh:unreachable:/repo/specs/tasks.md"
          default-directory "/ssh:unreachable:/repo/specs/")
    ;; Load TRAMP's local configuration before counting filesystem probes.
    (should (file-remote-p buffer-file-name))
    (let (diagnostics)
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (&rest _) (ert-fail "Remote probe")))
                ((symbol-function 'valsi-plan--reference-directories)
                 (lambda (&rest _) (ert-fail "Remote project discovery"))))
        (valsi-plan-flymake (lambda (result) (setq diagnostics result))))
      (should diagnostics)
      (should (cl-some (lambda (diagnostic)
                         (string-match-p "duplicate" (flymake-diagnostic-text diagnostic)))
                       diagnostics)))))

(ert-deftest valsi-plan-path-terminal-handoff-names-base-and-fallback ()
  "Terminal file hints identify the project base and rebase plan-local files."
  (valsi-plan-path-test--with-project "specs/001"
    (make-directory (expand-file-name "local" plan-dir))
    (with-temp-file (expand-file-name "local/notes.el" plan-dir) (insert "notes"))
    (erase-buffer)
    (insert "- [ ] T001 `src/code.el` `local/notes.el` `src/new.el`\n")
    (let* ((root (valsi-plan--buffer-tree))
           (task (car (valsi-node-of-type root 'task)))
           (prompt (valsi-plan--terminal-prompt root task)))
      (should (string-match-p
               "Files: src/code.el, specs/001/local/notes.el, src/new.el" prompt))
      (should (string-search (concat "File paths are relative to: " project-dir) prompt))
      ;; The wire bundle stays pure and preserves lexical path hints.
      (should (equal '("src/code.el" "local/notes.el" "src/new.el")
                     (plist-get (valsi-plan-context-bundle root task) :files))))))

(ert-deftest valsi-plan-path-complete-children-preserves-nontasks-and-cancelled ()
  "Completion uses parsed tasks and preserves cancelled or unknown states."
  (with-temp-buffer
    (insert "- [ ] 1 Parent\n"
            "  - [c] 1.1 Cancelled\n  - [C] 1.2 Also cancelled\n"
            "  - [?] 1.3 Unknown\n  - [-] 1.4 Active\n  - [~] 1.5 Active too\n"
            "```markdown\n  - [ ] 1.6 Example\n```\n"
            "  - [ ] 1.7 Open\n- [ ] 2 Sibling\n")
    (goto-char (point-min))
    (valsi-plan-complete-with-children)
    (should (equal (buffer-string)
                   (concat "- [x] 1 Parent\n"
                           "  - [c] 1.1 Cancelled\n  - [C] 1.2 Also cancelled\n"
                           "  - [?] 1.3 Unknown\n  - [x] 1.4 Active\n  - [x] 1.5 Active too\n"
                           "```markdown\n  - [ ] 1.6 Example\n```\n"
                           "  - [x] 1.7 Open\n- [ ] 2 Sibling\n")))))

(provide 'valsi-plan-path-test)
;;; valsi-plan-path-test.el ends here

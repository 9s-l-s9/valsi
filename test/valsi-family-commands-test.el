;;; valsi-family-commands-test.el --- Family command coverage -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Direct precedence, status, discovery, navigation and dashboard checks.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi)
(require 'valsi-changelog)
(require 'valsi-decision)

(ert-deftest valsi-family-commands-semver-tables ()
  "Numeric, lexical, prefix and build identifiers follow SemVer precedence."
  (dolist (case '(("1.9.0" "1.10.0" -1) ("2.0.0" "1.99.99" 1)
                  ("1.0.1" "1.0.0" 1) ("1.0.0" "1.0.0" 0)
                  ("1.0.0-alpha" "1.0.0" -1)
                  ("1.0.0-alpha" "1.0.0-alpha.1" -1)
                  ("1.0.0-alpha.1" "1.0.0-alpha.beta" -1)
                  ("1.0.0-beta.2" "1.0.0-beta.11" -1)
                  ("1.0.0-beta" "1.0.0-rc.1" -1)
                  ("1.0.0+build.1" "1.0.0+build.2" 0)
                  ("1.0.0-rc.1+a" "1.0.0-rc.1+b" 0)))
    (pcase-let ((`(,a ,b ,expected) case))
      (should (= expected (valsi-changelog-version-compare a b)))
      (should (= (- expected) (valsi-changelog-version-compare b a)))))
  (dolist (case '((nil nil 0) (nil ("a") -1)
                  (("2") ("10") -1) (("9") ("a") -1)
                  (("a") ("b") -1) (("a") ("a" "1") -1)
                  (("a" "1") ("a" "1") 0)))
    (pcase-let ((`(,a ,b ,expected) case))
      (should (= expected (valsi-changelog--prerelease-compare a b)))
      (should (= (- expected) (valsi-changelog--prerelease-compare b a))))))

(ert-deftest valsi-family-commands-status-helpers ()
  "Status normalization remains descriptive; lifecycle validation is strict."
  (dolist (case '((" * **accepted** " "Accepted" t)
                  ("1. `proposed`" "Proposed" t)
                  ("superseded by ADR-0012" "Superseded by ADR-0012" t)
                  ("Superseded by 7" "Superseded by 7" t)
                  ("Superseded" "Superseded" nil)
                  ("Acceptedish" "Acceptedish" nil)
                  ("" "" nil)))
    (pcase-let ((`(,input ,expected ,valid) case))
      (should (equal expected (valsi-decision--status-of input)))
      (should (eq valid (not (null (valsi-decision--standard-status-p expected)))))))
  (dolist (case '(("---\nstatus: 'accepted'\n---\n# X\n"
                   "---\nstatus: 'rejected'\n---\n# X\n" t)
                  ("# X\nStatus: Proposed\n## Context\nStatus: ignore\n"
                   "# X\nStatus: Rejected\n## Context\nStatus: ignore\n" t)
                  ("# X\n## Context\nStatus: ignore\n"
                   "# X\n## Context\nStatus: ignore\n" nil)))
    (with-temp-buffer
      (insert (car case))
      (should (eq (nth 2 case) (valsi-decision--set-status-key "Rejected")))
      (should (equal (nth 1 case) (buffer-string))))))

(ert-deftest valsi-family-commands-adr-discovery ()
  "Own ADR directories win; unrelated buffers and absent roots are handled."
  (let ((root (make-temp-file "valsi-discovery-" t)))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory (file-name-as-directory root))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
            (should-not (valsi-decision--dir))
            (setq buffer-file-name (expand-file-name "notes.md" root))
            (should (equal default-directory (valsi-decision--dir)))
            (make-directory (expand-file-name "docs/decisions" root) t)
            (should (equal (expand-file-name "docs/decisions" root)
                           (valsi-decision--dir)))
            (make-directory (expand-file-name "doc/adr" root) t)
            (should (equal (expand-file-name "doc/adr" root) (valsi-decision--dir)))
            (setq buffer-file-name (expand-file-name "docs/decisions/use-x.md" root))
            (should (equal (file-name-directory buffer-file-name) (valsi-decision--dir)))))
      (delete-directory root t)))
  (dolist (case '(("0001-a.md" "# A\n" t)
                  ("use-x.md" "# A\nStatus: Proposed\n" t)
                  ("use-x.md" "# A\n## Decision Outcome\n" t)
                  ("notes.md" "# A\n## Details\n" nil)
                  ("README.md" "# A\nStatus: Accepted\n" nil)
                  ("index.md" "## Decision\n" nil)
                  ("0002-template.md" "## Decision\n" nil)))
    (should (eq (nth 2 case)
                (not (null (valsi-decision--adr-p
                            (car case) (valsi-decision-parse (nth 1 case)))))))))

(ert-deftest valsi-family-commands-changelog-navigation-info-dashboard ()
  "Commands navigate releases, summarize them and refresh the source table."
  (save-window-excursion
    (with-temp-buffer
      (insert "# Changes\n## [Unreleased]\n### Added\n- New\n## [1.0.0] - 2026-01-01\n### Fixed\n- Old\n")
      (let ((source (current-buffer)) dashboard)
        (unwind-protect
            (progn
              (setq buffer-file-name "/tmp/valsi-family-commands/CHANGELOG.md")
              (valsi-artifact-minor-mode 1)
              (goto-char (point-min))
              (call-interactively #'valsi-changelog-next-release)
              (should (looking-at "## \\[Unreleased\\]"))
              (should (equal "Unreleased — 1 categories, 1 entries"
                             (valsi-changelog-info)))
              (valsi-changelog-next-release)
              (should (looking-at "## \\[1.0.0\\]"))
              (let ((position (point)))
                (valsi-changelog-next-release)
                (should (= position (point))))
              (valsi-changelog-previous-release)
              (should (looking-at "## \\[Unreleased\\]"))
              (goto-char (point-min))
              (should (equal "No release at point" (valsi-changelog-info)))
              (call-interactively #'valsi-changelog-dashboard)
              (setq dashboard (current-buffer))
              (should (derived-mode-p 'tabulated-list-mode))
              (should (equal '("Unreleased" "1.0.0")
                             (mapcar (lambda (row) (aref (cadr row) 0)) tabulated-list-entries)))
              (with-current-buffer source
                (valsi-enter-insert)
                (goto-char (point-max))
                (insert "## [0.9.0]\n- Earlier\n"))
              (revert-buffer)
              (should (= 3 (length tabulated-list-entries)))
              (goto-char (point-min))
              (valsi-view-visit-source)
              (should (eq source (current-buffer)))
              (should (looking-at "## \\[Unreleased\\]")))
          (when (buffer-live-p dashboard) (kill-buffer dashboard)))))))

(ert-deftest valsi-family-commands-decision-info-dashboard-visit ()
  "Decision commands report metadata, display ADR rows and visit a chosen file."
  (let* ((root (make-temp-file "valsi-dashboard-" t))
         (file (expand-file-name "0001-first.md" root)) dashboard)
    (unwind-protect
        (progn
          (with-temp-file file (insert "# First\nStatus: Accepted\n## Context\nWhy\n"))
          (with-temp-file (expand-file-name "README.md" root) (insert "# Index\n"))
          (save-window-excursion
            (with-temp-buffer
              (insert "# First\nStatus: Accepted\n## Context\nWhy\n")
              (setq buffer-file-name file valsi--grammar 'decision
                    default-directory (file-name-as-directory root))
              (valsi-artifact-minor-mode 1)
              (should (equal "ADR: First [status: Accepted] sections: Context"
                             (valsi-decision-info)))
              (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
                (call-interactively #'valsi-decision-dashboard))
              (setq dashboard (current-buffer))
              (should (= 1 (length tabulated-list-entries)))
              (should (equal (vector "0001-first.md" "First" "Accepted")
                             (cadar tabulated-list-entries)))
              (should (eq #'valsi-decision--visit (key-binding (kbd "RET"))))
              (goto-char (point-min))
              (let (visited)
                (cl-letf (((symbol-function 'find-file-other-window)
                           (lambda (path &rest _) (setq visited path))))
                  (call-interactively #'valsi-decision--visit))
                (should (equal file visited))))))
      (when (buffer-live-p dashboard) (kill-buffer dashboard))
      (delete-directory root t))))

(provide 'valsi-family-commands-test)
;;; valsi-family-commands-test.el ends here

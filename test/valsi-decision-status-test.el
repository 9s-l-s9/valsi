;;; valsi-decision-status-test.el --- ADR status editing -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Empty records remain editable; status changes and fontification use only
;; the actual status field, not examples or lifecycle words in ordinary prose.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-decision)

(defun valsi-decision-status-test--choose (choice &optional number)
  "Set the current buffer's status to CHOICE with superseding NUMBER."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt _choices _predicate require-match &rest _)
               (should require-match)
               choice))
            ((symbol-function 'read-string)
             (lambda (&rest _) (or number (ert-fail "Unexpected ADR prompt")))))
    (valsi-decision-set-status)))

(ert-deftest valsi-decision-status-empty-records-offer-action ()
  "All recognized ADRs can set a status, even empty sections, keys and templates."
  (dolist (text '("# Bare\n" "# Empty section\n\n## Status\n\n## Context\n"
                  "---\nstatus:\n---\n# Empty key\n" "# Empty inline\nStatus: \n"
                  "# Empty bold\n* **Status:**\n"))
    (let ((root (valsi-decision-parse text)))
      (should-not (valsi-node-prop root :status))
      (should (memq 'set-status (valsi-decision-capabilities root))))
    (with-temp-buffer
      (insert text)
      (valsi-decision-status-test--choose "Accepted")
      (should (equal "Accepted"
                     (valsi-node-prop (valsi-decision-parse (buffer-string)) :status))))))

(ert-deftest valsi-decision-status-refuses-empty-or-unknown-input ()
  "Empty input and typos cannot destroy an existing status."
  (dolist (choice '("" "  " "Acepted" "custom lifecycle"))
    (with-temp-buffer
      (insert "# Record\n## Status\nAccepted\n")
      (let ((before (buffer-string)))
        (should-error (valsi-decision-status-test--choose choice) :type 'user-error)
        (should (equal before (buffer-string)))))))

(ert-deftest valsi-decision-status-superseded-requires-reference ()
  "Superseded asks for a valid ADR and formats the result consistently."
  (dolist (number '("12" "0012" "ADR-0012" "adr12"))
    (with-temp-buffer
      (insert "# Record\n## Status\nAccepted\n")
      (valsi-decision-status-test--choose "Superseded" number)
      (should (string-suffix-p "Superseded by ADR-0012\n" (buffer-string)))))
  (dolist (number '("" "-1" "12 extra" "../doc.md" "ADR-x"))
    (with-temp-buffer
      (insert "# Record\n## Status\nAccepted\n")
      (let ((before (buffer-string)))
        (should-error (valsi-decision-status-test--choose "Superseded" number)
                      :type 'user-error)
        (should (equal before (buffer-string)))))))

(ert-deftest valsi-decision-status-key-preserves-format ()
  "Replacing frontmatter and preamble values keeps quotes, case and other text."
  (dolist (case '(("status: 'proposed'" . "status: 'accepted'")
                  ("status: \"proposed\"" . "status: \"accepted\"")
                  ("Status: Proposed" . "Status: Accepted")
                  ("* **Status:** Proposed" . "* **Status:** Accepted")
                  ("* **Status:**" . "* **Status:** Accepted")
                  ("Status: Proposed  \t" . "Status: Accepted  \t")
                  ("status: ''" . "status: 'Accepted'")
                  ("Status: " . "Status: Accepted")))
    (with-temp-buffer
      (insert "# Record\n" (car case) "\n## Context\nAccepted in prose.\n")
      (should (valsi-decision--set-status-key "Accepted"))
      (should (equal (buffer-string)
                     (concat "# Record\n" (cdr case)
                             "\n## Context\nAccepted in prose.\n"))))))

(ert-deftest valsi-decision-status-fenced-examples-are-not-fields ()
  "The editor updates only the parsed field, preserving examples in fences."
  (with-temp-buffer
    (insert "# Record\n```yaml\nStatus: example\n```\nStatus: Proposed\n")
    (valsi-decision-status-test--choose "Accepted")
    (should (equal (buffer-string)
                   "# Record\n```yaml\nStatus: example\n```\nStatus: Accepted\n")))
  (dolist (existing '(nil t))
    (with-temp-buffer
      (insert "# Record\n## Status\n\n```text\nAccepted\n```\n")
      (when existing (insert "Proposed\n"))
      (insert "## Context\nKeep me.\n")
      (valsi-decision-status-test--choose "Rejected")
      (should (string-search "```text\nAccepted\n```" (buffer-string)))
      (should (equal "Rejected"
                     (valsi-node-prop (valsi-decision-parse (buffer-string)) :status)))
      (should (string-suffix-p "## Context\nKeep me.\n" (buffer-string))))))

(ert-deftest valsi-decision-status-narrowing-and-case-insensitive-choice ()
  "A narrowed body can update the full record without losing its restriction."
  (with-temp-buffer
    (insert "# Record\nStatus: Proposed\n## Context\nAccepted in prose.\n")
    (goto-char (point-min))
    (forward-line 2)
    (narrow-to-region (point) (point-max))
    (valsi-decision-status-test--choose "accepted")
    (should (equal "## Context\nAccepted in prose.\n" (buffer-string)))
    (widen)
    (should (string-search "Status: Accepted\n" (buffer-string)))))

(ert-deftest valsi-decision-status-normalization-and-standard-values ()
  "Normalization is descriptive; lint distinguishes complete lifecycle values."
  (dolist (case '(("**accepted**" "Accepted" t)
                  ("- proposed" "Proposed" t)
                  ("1) Superseded by ADR-0012" "Superseded by ADR-0012" t)
                  ("superseded by 12" "Superseded by 12" t)
                  ("Superseded" "Superseded" nil)
                  ("Acceptedish" "Acceptedish" nil)
                  ("waiting for review" "waiting for review" nil)))
    (let ((status (valsi-decision--status-of (car case))))
      (should (equal (cadr case) status))
      (should (eq (nth 2 case) (and (valsi-decision--standard-status-p status) t))))))

(ert-deftest valsi-decision-status-fontification-is-scoped-and-invalidated ()
  "Only the actual status word gets its lifecycle face, including after edits."
  (dolist (text '("# Record\nStatus: Proposed\n## Context\nAccepted in prose.\n"
                  "---\nstatus: proposed\n---\n# Record\n## Context\nAccepted in prose.\n"
                  "# Record\n## Status\n\nProposed\n## Context\nAccepted in prose.\n"
                  "# Record\n```\nStatus: Accepted\n```\nStatus: Proposed\n"))
    (with-temp-buffer
      (text-mode)
      (insert text)
      (setq-local font-lock-defaults '(valsi-decision-font-lock-keywords))
      (font-lock-ensure)
      (goto-char (point-min))
      (search-forward "Proposed" nil t)
      (unless (match-beginning 0) (ert-fail "Missing lifecycle word"))
      (should (eq 'valsi-id-face (get-text-property (1- (point)) 'face)))
      (goto-char (point-min))
      (search-forward "Accepted")
      (should-not (eq 'valsi-id-face (get-text-property (1- (point)) 'face)))
      (goto-char (point-min))
      (let ((case-fold-search t))
        (re-search-forward "Proposed")
        (replace-match "Rejected" t t))
      (font-lock-flush)
      (font-lock-ensure)
      (goto-char (point-min))
      (search-forward "Rejected")
      (should (eq 'valsi-id-face (get-text-property (1- (point)) 'face))))))

(provide 'valsi-decision-status-test)
;;; valsi-decision-status-test.el ends here

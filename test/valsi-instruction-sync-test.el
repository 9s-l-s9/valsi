;;; valsi-instruction-sync-test.el --- Safe instruction sync -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Test large and malformed regions, reverse sync, and visiting-buffer safety.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi-instruction)

(defun valsi-instruction-sync-test--block (text)
  "Wrap TEXT in one managed sync region."
  (concat valsi-instruction-sync-begin "\n" text "\n" valsi-instruction-sync-end))

(defun valsi-instruction-sync-test--read (file)
  "Return FILE's text."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defmacro valsi-instruction-sync-test--with-peers (&rest body)
  "Run BODY with isolated SOURCE, PEER, OTHER files and prompt controls."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "valsi-sync-" t))
          (source (expand-file-name "AGENTS.md" directory))
          (peer (expand-file-name "CLAUDE.md" directory))
          (other (expand-file-name "GEMINI.md" directory))
          (before (buffer-list))
          (picked '("CLAUDE.md"))
          (confirm (lambda (_) t))
          (valsi-global-mode nil))
     (unwind-protect
         (progn
           (with-temp-file source (insert "# Shared\n\n- first\n- last\n"))
           (with-temp-file peer (insert "# Claude local\n"))
           (with-temp-file other (insert "# Gemini local\n"))
           (cl-letf (((symbol-function 'completing-read-multiple)
                      (lambda (&rest _) picked))
                     ((symbol-function 'y-or-n-p) (lambda (prompt) (funcall confirm prompt))))
             (with-current-buffer (find-file-noselect source)
               ,@body)))
       (dolist (buffer (seq-difference (buffer-list) before))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory directory t))))

(ert-deftest valsi-instruction-sync-large-region ()
  "Repeated sync of a large region is bounded and preserves surrounding bytes."
  (let* ((large (make-string 200000 ?x))
         (prefix "local prefix \t\n\n")
         (suffix "\n\nlocal suffix \t\n")
         (target (concat prefix (valsi-instruction-sync-test--block large) suffix))
         (updated (valsi-instruction--sync-region "new" target)))
    (should (equal updated
                   (concat prefix (valsi-instruction-sync-test--block "new") suffix)))
    (should (equal target (valsi-instruction--sync-region large target)))))

(ert-deftest valsi-instruction-sync-append-preserves-whitespace ()
  "Appending the first managed region never trims a peer's local text."
  (dolist (target '("" " \t" "# Local \t" "# Local\n\n \t\n"))
    (let ((updated (valsi-instruction--sync-region "shared" target)))
      (should (string-prefix-p target updated))
      (should (equal updated (valsi-instruction--sync-region "shared" updated))))))

(ert-deftest valsi-instruction-sync-reverse-omits-imports ()
  "A to B to A imports only B's own text, without nesting A's imported block."
  (let* ((a "# A own\n")
         (b (valsi-instruction--sync-region a "# B own\n"))
         (back (valsi-instruction--sync-region b a)))
    (should (equal back (concat "# A own\n\n"
                                (valsi-instruction-sync-test--block "# B own") "\n")))
    (should (equal back (valsi-instruction--sync-region b back)))))

(ert-deftest valsi-instruction-sync-repairs-nested-and-duplicate-regions ()
  "Old nested and duplicate regions become one block, preserving outside text."
  (let* ((nested (valsi-instruction-sync-test--block
                  (concat "outer\n" (valsi-instruction-sync-test--block "inner"))))
         (target (concat "before\n" nested "\nbetween\n"
                         (valsi-instruction-sync-test--block "duplicate") "\nafter\n")))
    (should (equal (valsi-instruction--sync-region "new" target)
                   (concat "before\n" (valsi-instruction-sync-test--block "new")
                           "\nbetween\n\nafter\n")))
    (should (equal (valsi-instruction--sync-region (concat "own\n" nested) "")
                   (concat (valsi-instruction-sync-test--block "own") "\n")))))

(ert-deftest valsi-instruction-sync-rejects-unmatched-markers ()
  "Ambiguous markers cannot truncate either source or target."
  (dolist (text (list valsi-instruction-sync-begin valsi-instruction-sync-end
                      (concat valsi-instruction-sync-begin
                              (valsi-instruction-sync-test--block "nested"))))
    (should-error (valsi-instruction--sync-region text "local") :type 'user-error)
    (should-error (valsi-instruction--sync-region "shared" text) :type 'user-error)))

(ert-deftest valsi-instruction-sync-narrowed-source-and-open-peer ()
  "Full source reaches a clean open peer; its buffer, disk and modtime agree."
  (valsi-instruction-sync-test--with-peers
    (let* ((text (buffer-string))
           (destination (find-file-noselect peer))
           (expected (valsi-instruction--sync-region text "# Claude local\n")))
      (goto-char (point-min))
      (forward-line 2)
      (narrow-to-region (point) (line-end-position))
      (let ((minimum (point-min)) (maximum (point-max)))
        (valsi-instruction-sync)
        (should (= minimum (point-min)))
        (should (= maximum (point-max))))
      (should (equal expected (valsi-instruction-sync-test--read peer)))
      (with-current-buffer destination
        (should (equal expected (buffer-string)))
        (should-not (buffer-modified-p))
        (should (verify-visited-file-modtime destination))))))

(ert-deftest valsi-instruction-sync-preflights-all-peers ()
  "A modified later peer refuses the operation before any target is written."
  (valsi-instruction-sync-test--with-peers
    (setq picked '("CLAUDE.md" "GEMINI.md")
          confirm (lambda (_) (ert-fail "Prompted before validating every peer")))
    (with-current-buffer (find-file-noselect other)
      (goto-char (point-max))
      (insert "unsaved\n"))
    (should-error (valsi-instruction-sync) :type 'user-error)
    (should (equal "# Claude local\n" (valsi-instruction-sync-test--read peer)))
    (should (equal "# Gemini local\n" (valsi-instruction-sync-test--read other)))
    (with-current-buffer (find-buffer-visiting other)
      (should (buffer-modified-p))
      (should (string-suffix-p "unsaved\n" (buffer-string))))))

(ert-deftest valsi-instruction-sync-refuses-stale-open-peer ()
  "An externally changed peer is not silently reverted or overwritten."
  (valsi-instruction-sync-test--with-peers
    (let ((destination (find-file-noselect peer)))
      (with-temp-file peer (insert "external change\n"))
      (set-file-times peer (time-add (current-time) 10))
      (should-error (valsi-instruction-sync) :type 'user-error)
      (should (equal "external change\n" (valsi-instruction-sync-test--read peer)))
      (with-current-buffer destination
        (should (equal "# Claude local\n" (buffer-string)))))))

(ert-deftest valsi-instruction-sync-rechecks-after-confirmation ()
  "An edit or disk change while the confirmation is open cannot be overwritten."
  (dolist (on-disk '(nil t))
    (valsi-instruction-sync-test--with-peers
      (setq confirm
            (lambda (_)
              (if on-disk
                  (progn
                    (with-temp-file peer (insert "changed during prompt\n"))
                    (set-file-times peer (time-add (current-time) 10)))
                (with-current-buffer (find-buffer-visiting peer)
                  (goto-char (point-max)) (insert "changed during prompt\n")))
              t))
      (should-error (valsi-instruction-sync) :type 'user-error)
      (if on-disk
          (should (equal "changed during prompt\n"
                         (valsi-instruction-sync-test--read peer)))
        (should (equal "# Claude local\n" (valsi-instruction-sync-test--read peer)))
        (should (buffer-modified-p (find-buffer-visiting peer)))))))

(ert-deftest valsi-instruction-sync-decline-and-source-alias ()
  "Declining writes and selecting a symlink to the source leave files intact."
  (valsi-instruction-sync-test--with-peers
    (setq confirm (lambda (_) nil))
    (valsi-instruction-sync)
    (should (equal "# Claude local\n" (valsi-instruction-sync-test--read peer)))
    (delete-file peer)
    (make-symbolic-link source peer)
    (setq confirm (lambda (_) (ert-fail "Should skip the source's alias")))
    (valsi-instruction-sync)
    (should (equal (buffer-string) (valsi-instruction-sync-test--read source)))))

(ert-deftest valsi-instruction-sync-creates-missing-peer ()
  "A new peer is saved and its temporary visiting buffer is cleaned up."
  (valsi-instruction-sync-test--with-peers
    (delete-file peer)
    (valsi-instruction-sync)
    (should (equal (valsi-instruction--sync-region (buffer-string) "")
                   (valsi-instruction-sync-test--read peer)))
    (should-not (find-buffer-visiting peer))))

(provide 'valsi-instruction-sync-test)
;;; valsi-instruction-sync-test.el ends here

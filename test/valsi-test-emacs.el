;;; valsi-test-emacs.el --- Locate the running Emacs for child processes -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests that spawn a child Emacs must run the binary that is running the
;; tests (issue #83).  `invocation-directory' is not enough: a wrapper that
;; execs the real binary as "emacs" (Guix does this) makes Emacs resolve it
;; through PATH, which can name a different Emacs.  That Emacs then inherits
;; an EMACSLOADPATH built for this one and fails to load its own libraries.
;; The running executable itself, given the unchanged environment, interprets
;; EMACSLOADPATH exactly as this process did.

;;; Code:

(defun valsi-test-emacs-program ()
  "Return the executable of the running Emacs, or nil if none is found."
  (let ((self (and (file-exists-p "/proc/self/exe")
                   (file-truename "/proc/self/exe")))
        (invoked (expand-file-name invocation-name invocation-directory)))
    (cond ((and self (file-executable-p self)) self)
          ((file-executable-p invoked) invoked))))

(provide 'valsi-test-emacs)
;;; valsi-test-emacs.el ends here

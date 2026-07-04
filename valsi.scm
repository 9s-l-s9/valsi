;;; valsi.scm --- Guix package + reproducible dev shell for Valsi
;;;
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;
;;; Usage:
;;;   guix build -f valsi.scm                 ; build + byte-compile the package
;;;   guix shell -D -f valsi.scm -- make check ; dev shell (build deps) + tests
;;;   guix shell -f valsi.scm                 ; a profile with Valsi installed
;;;
;;; The dev shell mirrors the Makefile's pinned tool set
;;; (nss-certs + emacs + emacs-markdown-mode); see the Makefile `guix-check'
;;; target.  Emacs floor is 29.1; CI/dev run on 30.2 (ADR 0002).

(use-modules (guix packages)
             (guix gexp)
             (guix git-download)
             (guix build-system emacs)
             ((guix licenses) #:prefix license:)
             (gnu packages emacs)
             (gnu packages emacs-xyz)
             (gnu packages nss))

(define %source-dir (dirname (current-filename)))

(package
  (name "emacs-valsi")
  (version "1.0")
  (source (local-file %source-dir "valsi-checkout"
                      #:recursive? #t
                      #:select? (lambda (file stat)
                                  ;; Ship sources + docs; skip VCS + build junk.
                                  (not (or (string-contains file "/.git")
                                           (string-suffix? ".elc" file)
                                           (string-suffix? "~" file)
                                           (string-contains file "/#"))))))
  (build-system emacs-build-system)
  (arguments
   (list
    ;; The library lives in lisp/; compile + install from there so the flat
    ;; valsi-*.el land on the site load-path and their inter-`require's resolve.
    #:phases
    #~(modify-phases %standard-phases
        (add-after 'unpack 'enter-lisp
          (lambda _ (chdir "lisp"))))))
  ;; markdown-mode is the real runtime dependency (the client layers on it).
  (propagated-inputs (list emacs-markdown-mode))
  ;; nss-certs is here so the dev shell has the TLS roots the R-track needs.
  (native-inputs (list nss-certs))
  (home-page "https://github.com/s-l-s/valsi")
  (synopsis "Grammar-aware Emacs harness for agent artifacts (AAP reference impl)")
  (description
   "Valsi is an Emacs client/server harness for the structured markdown
artifacts agents read and write --- plan/tasks, instruction (AGENTS.md/
CLAUDE.md), prompt-file (SKILL.md/subagents/commands), and memory --- unified
by a cross-artifact link graph.  Grammars are @emph{descriptive}: tolerant
recognizers over plain markdown that annotate but never reject, so files stay
ordinary and portable.  It is the reference implementation of the Agent
Artifact Protocol (AAP), an LSP-style wire protocol whose grammars are
hot-registrable plugins.")
  (license license:gpl3+))

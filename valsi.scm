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
;;; (nss-certs + emacs + emacs-markdown-mode + emacs-eat); see `guix-check'
;;; target.  Emacs floor is 29.1; CI/dev run on 30.2 (ADR 0002).

(use-modules (guix packages)
             (guix gexp)
             (guix download)
             (guix git-download)
             (guix build-system copy)
             (guix build-system emacs)
             ((guix licenses) #:prefix license:)
             (gnu packages base)
             (gnu packages bash)
             (gnu packages emacs)
             (gnu packages emacs-xyz)
             (gnu packages nss)
             (gnu packages virtualization))

(define %source-dir (dirname (current-filename)))

(define %pi-version "0.80.6")

(define (pi-release-asset system)
  "Return the release asset name, hash, and ELF loader for SYSTEM."
  (cond
   ((string-prefix? "x86_64-linux" system)
    (list "pi-linux-x64.tar.gz"
          "0f8qnxyc32i8ylgshxxg2ra2jvnqmq5z97i4fiqvjdpkvfrq7hzp"
          "/lib/ld-linux-x86-64.so.2"))
   ((string-prefix? "aarch64-linux" system)
    (list "pi-linux-arm64.tar.gz"
          "0l00w07fijmwl3ha63b7l6xy1h0kn5qxx4m2zch941v7433ib0rv"
          "/lib/ld-linux-aarch64.so.1"))
   (else
    (error "Pi 0.80.6 has no packaged release asset for system" system))))

(define pi-runtime
  (let* ((system (or (%current-target-system) (%current-system)))
         (asset (pi-release-asset system))
         (archive (car asset))
         (hash (cadr asset))
         (loader (caddr asset)))
    (package
      (name "pi-coding-agent")
      (version %pi-version)
      (source
       (origin
         (method url-fetch)
         (uri (string-append
               "https://github.com/earendil-works/pi/releases/download/v"
               version "/" archive))
         (sha256 (base32 hash))))
      (build-system copy-build-system)
      (arguments
       (list
        #:install-plan #~'(("." "libexec/pi"))
        #:phases
        #~(modify-phases %standard-phases
            ;; Bun appends its application payload to the ELF executable, so
            ;; patchelf would invalidate internal offsets.  Keep the release
            ;; binary byte-for-byte and launch it in a tiny mount namespace
            ;; that supplies the conventional dynamic-loader path it expects.
            (add-after 'install 'install-launcher
              (lambda* (#:key outputs #:allow-other-keys)
                (let* ((out (assoc-ref outputs "out"))
                       (bin (string-append out "/bin"))
                       (launcher (string-append bin "/pi"))
                       (runtime (string-append out "/libexec/pi/pi")))
                  (mkdir-p bin)
                  (call-with-output-file launcher
                    (lambda (port)
                      (format port
                              "#!~a/bin/bash
set -eu
pi_home=\"${HOME:?HOME must be set}\"
if [[ ! -d \"$pi_home\" ]]; then
  pi_home=\"/tmp/valsi-pi-home-${UID}\"
  mkdir -p \"$pi_home\"
fi
bwrap_args=( \\
  --tmpfs / \\
  --ro-bind /gnu /gnu \\
  --ro-bind /etc /etc )
if [[ -d /sys ]]; then
  bwrap_args+=(--ro-bind /sys /sys)
fi
bwrap_args+=( \\
  --proc /proc \\
  --dev /dev \\
  --bind /tmp /tmp \\
  --bind \"$pi_home\" \"$pi_home\" \\
  --setenv HOME \"$pi_home\" \\
  --dir /lib64 \\
  --ro-bind ~a /lib64/~a )
exec ~a/bin/bwrap \"${bwrap_args[@]}\" ~a \"$@\"
"
                              #$bash-minimal
                              #$(file-append glibc loader)
                              #$(basename loader)
                              #$bubblewrap
                              runtime)))
                  (chmod launcher #o555))))
            (delete 'strip)
            (delete 'validate-runpath))))
      (inputs (list bash-minimal bubblewrap glibc))
      (supported-systems '("x86_64-linux" "aarch64-linux"))
      (home-page "https://github.com/earendil-works/pi")
      (synopsis "Pi coding-agent runtime")
      (description
       "This package installs the upstream, Bun-compiled Pi coding-agent
runtime.  It is pinned to a checksummed release and kept byte-for-byte intact;
a Bubblewrap launcher supplies Guix's dynamic loader at the conventional path
expected by the executable.  This provides the @command{pi} CLI and JSONL RPC
server without a global npm installation.")
      (license license:expat))))

(package
  (name "emacs-valsi")
  (version "1.0.0")
  (source (local-file %source-dir "valsi-checkout"
                      #:recursive? #t
                      #:select? (lambda (file stat)
                                  ;; Ship sources + docs; skip VCS + build junk.
                                  (not (or (string-contains file "/.git")
                                           (string-contains file "/.agents/")
                                           (string-contains file "/.codex/")
                                           (string-contains file "/.valsi/")
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
          (lambda _ (chdir "lisp")))
        ;; emacs-build-system's generic check phase cannot discover this
        ;; project's ERT entry point. Run the same authoritative target used
        ;; by developers.
        (replace 'check
          (lambda* (#:key tests? #:allow-other-keys)
            (when tests?
              (with-directory-excursion ".."
                (invoke "make" "check")))))
        (add-after 'check 'exclude-experimental-harness
          (lambda _
            ;; emacs-build-system installs every .el in this directory, not
            ;; only Makefile's product graph. Keep the gated Pi-harness
            ;; experiments in the repository, but do not expose them as
            ;; installed features.
            (for-each delete-file '("valsi-harness.el" "valsi-pi.el"))))
        (add-after 'install 'install-pi-extension
          (lambda* (#:key outputs #:allow-other-keys)
            (let* ((out (assoc-ref outputs "out"))
                   (library
                    (car (find-files out "^valsi-terminal-agent\\.el$")))
                   (target (string-append
                            (dirname library) "/valsi-pi-extension")))
              (mkdir-p target)
              (copy-recursively "../extensions/valsi-pi" target)))))))
  ;; markdown-mode, Eat, and the pinned Pi CLI are runtime dependencies.
  (propagated-inputs (list emacs-markdown-mode emacs-eat pi-runtime))
  ;; Make an installed profile discover Valsi in both ordinary and -Q Emacs
  ;; launches.  emacs-build-system installs the files below this directory,
  ;; but package profiles do not inherit Emacs's own native search paths.
  (native-search-paths
   (list (search-path-specification
          (variable "EMACSLOADPATH")
          (files '("share/emacs/site-lisp")))))
  ;; nss-certs is here so the dev shell has the TLS roots the R-track needs.
  (native-inputs (list nss-certs))
  (home-page "https://github.com/9s-l-s9/valsi")
  (synopsis "Emacs application for agent artifacts and terminal agents")
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

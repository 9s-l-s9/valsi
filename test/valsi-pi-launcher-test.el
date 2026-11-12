;;; valsi-pi-launcher-test.el --- Launcher namespace checks -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run with VALSI_TEST_BASH, VALSI_TEST_BWRAP and VALSI_TEST_COREUTILS set to
;; Guix package directories, and VALSI_TEST_LOADER to the ELF loader file:
;;   make test TESTS=test/valsi-pi-launcher-test.el
;; These optional tests need unprivileged user namespaces; no agent is run.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)

(defconst valsi-pi-launcher-test--template
  (expand-file-name "../scripts/pi-launcher.sh.in"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Path to the launcher template under test.")

(defun valsi-pi-launcher-test--write (file text &optional executable)
  "Write TEXT to FILE, making it executable when EXECUTABLE is non-nil."
  (with-temp-file file (insert text))
  (when executable (set-file-modes file #o755)))

(defun valsi-pi-launcher-test--run (command)
  "Run COMMAND and return its exit status paired with stdout and stderr."
  (with-temp-buffer
    (let ((status (apply #'call-process (car command) nil t nil (cdr command))))
      (cons status (buffer-string)))))

(defun valsi-pi-launcher-test--check-layout (layout)
  "Exercise the real launcher with absent, directory or symlink LAYOUT."
  (let ((config (mapcar #'getenv '("VALSI_TEST_BASH" "VALSI_TEST_BWRAP"
                                  "VALSI_TEST_COREUTILS" "VALSI_TEST_LOADER"))))
    (unless (seq-every-p #'identity config)
      (ert-skip "Launcher test paths are not configured"))
    (pcase-let* ((`(,bash ,bwrap ,coreutils ,loader) config)
                 (root (make-temp-file "valsi-launcher-" t))
                 (target (expand-file-name (if (eq layout 'symlink) "usr/lib64" "lib64") root))
                 (template (with-temp-buffer
                             (insert-file-contents valsi-pi-launcher-test--template)
                             (buffer-string)))
                 (sockets nil))
      (unwind-protect
          (progn
            (dolist (replacement `(("BASH" . ,bash) ("BWRAP" . ,bwrap)
                                   ("COREUTILS" . ,coreutils) ("LOADER" . ,loader)
                                   ("LOADER_DIR" . "/lib64") ("LOADER_NAME" . "ld-test.so")
                                   ("RUNTIME" . ,(concat bash "/bin/bash"))))
              (setq template (replace-regexp-in-string
                              (concat "@" (car replacement) "@")
                              (cdr replacement) template t t)))
            (dolist (directory '("gnu" "proc" "dev" "tmp" "home/test" "srv/project"
                                  "run/user/1000" "var/guix" "bin" "usr/bin"))
              (make-directory (expand-file-name directory root) t))
            (make-symbolic-link (concat bash "/bin/bash") (expand-file-name "bin/sh" root))
            (make-symbolic-link (concat coreutils "/bin/env") (expand-file-name "usr/bin/env" root))
            (valsi-pi-launcher-test--write (expand-file-name "launcher" root) template t)
            (dolist (helper '(("shell" . "/bin/sh") ("env" . "/usr/bin/env bash")))
              (valsi-pi-launcher-test--write
               (expand-file-name (concat "srv/project/" (car helper)) root)
               (concat "#!" (cdr helper) "\nprintf 'helper-ok\\n'\n") t))
            (unless (eq layout 'absent)
              (make-directory target)
              (valsi-pi-launcher-test--write (expand-file-name "keep" target) "preserved")
              (make-symbolic-link "keep" (expand-file-name "alias" target))
              (valsi-pi-launcher-test--write (expand-file-name "ld-test.so" target) "old-loader")
              (when (eq layout 'symlink)
                (make-symbolic-link "usr/lib64" (expand-file-name "lib64" root))))
            (dolist (socket '("run/user/1000/agent.sock" "var/guix/daemon.sock"))
              (push (make-network-process :name "valsi-launcher-socket" :family 'local
                                          :service (expand-file-name socket root)
                                          :server t :noquery t)
                    sockets))
            (let* ((command (list (concat bwrap "/bin/bwrap") "--dev-bind" root "/"
                                  "--ro-bind" "/gnu" "/gnu" "--proc" "/proc" "--dev" "/dev"
                                  "--setenv" "HOME" "/home/test" "--setenv" "PATH"
                                  (concat bash "/bin:" coreutils "/bin") "--chdir" "/srv/project"))
                   (checks (concat "set -eu\n"
                                   "[[ \"$PWD\" == /srv/project && \"$HOME\" == /home/test ]]\n"
                                   "[[ -S /run/user/1000/agent.sock && -S /var/guix/daemon.sock ]]\n"
                                   "[[ -r /lib64/ld-test.so ]]\n"
                                   "[[ \"$(./shell)\" == helper-ok && \"$(./env)\" == helper-ok ]]\n"
                                   (unless (eq layout 'absent)
                                     "[[ \"$(cat /lib64/keep)\" == preserved && -L /lib64/alias ]]\n")))
                   (result (valsi-pi-launcher-test--run
                            (append command (list "/launcher" "-c" checks)))))
              (should (equal '(0 . "") result))
              (let ((invalid (valsi-pi-launcher-test--run
                              (append command '("--setenv" "HOME" "/missing"
                                                "/launcher" "-c" "exit 99")))))
                (should (eq 1 (car invalid)))
                (should (string-match-p "HOME must name an existing directory" (cdr invalid)))))
            (if (eq layout 'absent)
                (should-not (file-exists-p target))
              (should (equal "old-loader" (with-temp-buffer
                                             (insert-file-contents (expand-file-name "ld-test.so" target))
                                             (buffer-string)))))
            (should-not (file-exists-p (expand-file-name "missing" root))))
        (mapc #'delete-process sockets)
        (delete-directory root t)))))

(ert-deftest valsi-pi-launcher-absent-loader-directory ()
  "A missing loader directory is supplied without creating it on the host."
  (valsi-pi-launcher-test--check-layout 'absent))

(ert-deftest valsi-pi-launcher-existing-loader-directory ()
  "Existing loader contents, sockets, shebangs and the working directory survive."
  (valsi-pi-launcher-test--check-layout 'directory))

(ert-deftest valsi-pi-launcher-symlinked-loader-directory ()
  "A symlinked loader directory works without changing its host contents."
  (valsi-pi-launcher-test--check-layout 'symlink))

(provide 'valsi-pi-launcher-test)
;;; valsi-pi-launcher-test.el ends here

;;; valsi-terminal-agent.el --- Project-scoped terminal agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Thin lifecycle and display glue around real agent CLIs.  The selected CLI
;; owns its prompt, transcript, authentication, tools, and sessions; Valsi only
;; associates an Eat terminal with an Emacs project and agent name.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)

(defvar eat-terminal)
(declare-function eat-term-send-string-as-yank "eat" (terminal args))
(declare-function valsi "valsi-app")
(declare-function valsi-app-focus-agent "valsi-app")
(declare-function valsi-app-focus-artifacts "valsi-app")
(declare-function valsi-app-leave "valsi-app")
(declare-function valsi-agent-with-artifacts "valsi-app")

(defgroup valsi-terminal-agent nil
  "Terminal-native coding agents associated with Valsi projects."
  :group 'valsi)

(defcustom valsi-agent-terminal-backend 'pi
  "Backend used by `valsi-agent' when no backend is requested explicitly."
  :type '(choice (const pi) (const codex) (const claude) (const custom))
  :group 'valsi-terminal-agent)

(defcustom valsi-agent-terminal-backends
  '((pi :program "pi"
        :arguments ("--continue" "--provider" "openai-codex"
                    "--model" "gpt-5.5")
        :capability full)
    (codex :program "codex" :arguments nil :capability terminal)
    (claude :program "claude" :arguments nil :capability terminal)
    (custom :program nil :arguments nil :capability terminal))
  "Agent terminal backend declarations.
Each entry is (ID :program PROGRAM :arguments STRINGS :capability LEVEL).
The initial LEVEL values are `full' and `terminal'; they describe Valsi
integration, not the underlying CLI's coding capability."
  :type '(repeat
          (list symbol
                (const :program) (choice (const nil) string)
                (const :arguments) (repeat string)
                (const :capability) symbol))
  :group 'valsi-terminal-agent)

(defcustom valsi-agent-terminal-custom-command nil
  "Custom agent command as a list of PROGRAM followed by its arguments.
When nil, `valsi-agent' asks for a command when the custom backend is selected."
  :type '(choice (const nil) (repeat string))
  :group 'valsi-terminal-agent)

(defcustom valsi-agent-pi-extension-file nil
  "Optional path to Valsi's AAP-only Pi extension.
When nil, look beside the installed Lisp files and then in the source tree.
Pi remains usable without this extension, with terminal-only capability."
  :type '(choice (const nil) file)
  :group 'valsi-terminal-agent)

(cl-defstruct (valsi-terminal-agent-instance
               (:constructor valsi-terminal-agent-instance-create))
  "Lightweight metadata for one real agent terminal.
ROOT is the current logical project identity.  WORKTREE is the CLI's
execution directory; they are equal until linked-worktree discovery lands.
CAPABILITY describes Valsi integration, while TASK is an optional semantic
artifact reference.  No transcript, session, or credential data belongs here."
  name backend capability task root worktree buffer)

(defvar valsi-terminal-agent--instances (make-hash-table :test #'equal)
  "Map project-root/name keys to terminal agent instances.")

(defun valsi-terminal-agent-project-root (&optional directory)
  "Return canonical project root for DIRECTORY or `default-directory'."
  (let* ((default-directory (file-name-as-directory
                             (expand-file-name
                              (or directory default-directory))))
         (project (project-current nil default-directory))
         (root (if project (project-root project) default-directory)))
    (file-name-as-directory (file-truename root))))

(defun valsi-terminal-agent--project-name (root)
  "Return display name for project ROOT."
  (file-name-nondirectory (directory-file-name root)))

(defun valsi-terminal-agent--key (root name)
  "Return registry key for ROOT and agent NAME."
  (cons (file-truename root) name))

(defun valsi-terminal-agent--backend (backend)
  "Return declaration for BACKEND, or signal a user error."
  (or (assq backend valsi-agent-terminal-backends)
      (user-error "Unknown Valsi terminal backend: %s" backend)))

(defun valsi-terminal-agent--eat ()
  "Load Eat or explain the reproducible dependency."
  (unless (require 'eat nil t)
    (user-error
     (concat "Valsi agent terminals require Eat; install emacs-eat or run "
             "inside `guix shell -D -f valsi.scm'"))))

(defun valsi-terminal-agent--live-p (instance)
  "Return non-nil when INSTANCE has a live terminal process."
  (when-let* ((buffer (valsi-terminal-agent-instance-buffer instance)))
    (and (buffer-live-p buffer)
         (process-live-p (get-buffer-process buffer)))))

(defun valsi-terminal-agent--custom-command ()
  "Read a custom terminal program and return its declaration plist."
  (let* ((parts
          (or valsi-agent-terminal-custom-command
              (split-string-and-unquote
               (read-shell-command "Custom agent command: "))))
         (program (car parts)))
    (unless program
      (user-error "A custom agent command is required"))
    (list :program program :arguments (cdr parts) :capability 'terminal)))

(defun valsi-terminal-agent--ensure-program (program backend)
  "Return executable PROGRAM or explain how to configure BACKEND."
  (or (and program
           (if (file-name-absolute-p program)
               (and (file-executable-p program) program)
             (executable-find program)))
      (user-error
       "Cannot find `%s' for Valsi backend %s; install it or customize `%s'"
       program backend
       (if (eq backend 'custom)
           'valsi-agent-terminal-custom-command
         'valsi-agent-terminal-backends))))

(defun valsi-terminal-agent--pi-extension ()
  "Return the readable AAP-only Pi extension path, or nil."
  (let* ((library (or (locate-library "valsi-terminal-agent")
                      load-file-name
                      buffer-file-name))
         (lisp-dir (and library (file-name-directory library)))
         (candidates
          (delq nil
                (list valsi-agent-pi-extension-file
                      (and lisp-dir
                           (expand-file-name
                            "valsi-pi-extension/index.ts" lisp-dir))
                      (and lisp-dir
                           (expand-file-name
                            "../extensions/valsi-pi/index.ts" lisp-dir))))))
    (seq-find #'file-readable-p candidates)))

(defun valsi-terminal-agent--command-arguments (backend arguments)
  "Return ARGUMENTS augmented with Valsi integration for BACKEND."
  (if (not (eq backend 'pi))
      arguments
    (if-let* ((extension (valsi-terminal-agent--pi-extension)))
        (append arguments (list "--extension" extension))
      arguments)))

(defvar valsi-terminal-agent-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Only complete Valsi prefix sequences are captured.  All ordinary
    ;; terminal and CLI keys remain owned by Eat and the agent.
    (define-key map (kbd "C-c n c") #'valsi)
    (define-key map (kbd "C-c n a") #'valsi-app-focus-artifacts)
    (define-key map (kbd "C-c n f") #'valsi-app-focus-agent)
    (define-key map (kbd "C-c n 1") #'valsi-terminal-agent-focus)
    (define-key map (kbd "C-c n 2") #'valsi-agent-with-artifacts)
    (define-key map (kbd "C-c n q") #'valsi-app-leave)
    (define-key map (kbd "C-c n m") #'valsi-terminal-agent-help)
    ;; Pi enables terminal mouse reporting.  Without explicit higher-priority
    ;; bindings Eat forwards wheel events to Pi, where they navigate prompt
    ;; history instead of moving through terminal scrollback.
    (define-key map [wheel-up] #'mwheel-scroll)
    (define-key map [wheel-down] #'mwheel-scroll)
    (define-key map [mouse-4] #'mwheel-scroll)
    (define-key map [mouse-5] #'mwheel-scroll)
    map)
  "Terminal-safe Valsi workspace bindings.")

(defvar valsi-terminal-agent--emulation-map-alist
  `((valsi-terminal-agent-mode . ,valsi-terminal-agent-mode-map))
  "High-priority terminal bindings for Valsi agent buffers.")

(define-minor-mode valsi-terminal-agent-mode
  "Add Valsi workspace and scrollback bindings to an agent terminal."
  :lighter " Valsi-Agent"
  :keymap valsi-terminal-agent-mode-map
  ;; Eat dynamically enables its own mouse-reporting minor mode when a TUI
  ;; requests it.  Emulation maps precede those dynamic maps, ensuring the
  ;; four scrollback bindings above remain Emacs actions.
  (setq-local emulation-mode-map-alists
              (copy-sequence emulation-mode-map-alists))
  (if valsi-terminal-agent-mode
      (add-to-list 'emulation-mode-map-alists
                   'valsi-terminal-agent--emulation-map-alist)
    (setq emulation-mode-map-alists
          (delq 'valsi-terminal-agent--emulation-map-alist
                emulation-mode-map-alists))))

(defun valsi-terminal-agent-help ()
  "Show the deliberately small terminal workspace command set."
  (interactive)
  (message
   "Valsi terminal: C-c n c hub · a artifacts · f agent · 1 terminal · 2 composed · q leave"))

(defun valsi-terminal-agent--start (root name backend)
  "Start and return agent NAME using BACKEND at ROOT."
  (valsi-terminal-agent--eat)
  (let* ((decl (cdr (valsi-terminal-agent--backend backend)))
         (decl (if (eq backend 'custom)
                   (valsi-terminal-agent--custom-command)
                 decl))
         (program (valsi-terminal-agent--ensure-program
                   (plist-get decl :program) backend))
         (extension (and (eq backend 'pi)
                         (valsi-terminal-agent--pi-extension)))
         (arguments
          (valsi-terminal-agent--command-arguments
           backend (copy-sequence (plist-get decl :arguments))))
         (project-name (valsi-terminal-agent--project-name root))
         (terminal-name (format "Valsi Agent: %s/%s" project-name name))
         (default-directory root)
         (buffer
          (apply (symbol-function 'eat-make)
                 terminal-name program nil arguments))
         (instance
          (valsi-terminal-agent-instance-create
           :name name
           :backend backend
           :capability (if (and (eq backend 'pi) (null extension))
                           'terminal
                         (plist-get decl :capability))
           :task nil
           :root root
           :worktree root
           :buffer buffer)))
    (with-current-buffer buffer
      (setq-local default-directory root)
      (setq-local header-line-format
                  `(" Valsi AGENT · "
                    ,(symbol-name backend)
                    " · "
                    ,project-name
                    " · C-c n c hub · C-c n m menu "))
      (valsi-terminal-agent-mode 1))
    (puthash (valsi-terminal-agent--key root name)
             instance valsi-terminal-agent--instances)
    instance))

(defun valsi-terminal-agent-get (&optional root name)
  "Return live agent instance for ROOT and NAME, or nil."
  (let* ((root (or root (valsi-terminal-agent-project-root)))
         (name (or name "primary"))
         (instance
          (gethash (valsi-terminal-agent--key root name)
                   valsi-terminal-agent--instances)))
    (and instance (valsi-terminal-agent--live-p instance) instance)))

(defun valsi-terminal-agent-list (&optional root)
  "Return registered agent instances, optionally limited to ROOT."
  (let ((root (and root (file-truename root)))
        result)
    (maphash
     (lambda (_key instance)
       (when (or (null root)
                 (equal root
                        (file-truename
                         (valsi-terminal-agent-instance-root instance))))
         (push instance result)))
     valsi-terminal-agent--instances)
    (nreverse result)))

(defun valsi-terminal-agent--read-backend ()
  "Read one configured terminal backend."
  (intern
   (completing-read
    "Agent backend: "
    (mapcar (lambda (entry) (symbol-name (car entry)))
            valsi-agent-terminal-backends)
    nil t nil nil (symbol-name valsi-agent-terminal-backend))))

(defun valsi-terminal-agent--read-name (root &optional prompt)
  "Read an agent name at ROOT, using PROMPT when supplied."
  (let ((names
         (mapcar #'valsi-terminal-agent-instance-name
                 (valsi-terminal-agent-list root))))
    (completing-read (or prompt "Agent name: ") names nil nil nil nil
                     (if (member "primary" names) "primary" nil))))

(defun valsi-terminal-agent--target (&optional name)
  "Return the current project's live target agent, optionally named NAME."
  (let* ((root (valsi-terminal-agent-project-root))
         (instances
          (seq-filter #'valsi-terminal-agent--live-p
                      (valsi-terminal-agent-list root))))
    (or (and name (valsi-terminal-agent-get root name))
        (valsi-terminal-agent-get root "primary")
        (and (= (length instances) 1) (car instances))
        (and instances
             (let ((selected
                    (completing-read
                     "Insert into agent: "
                     (mapcar #'valsi-terminal-agent-instance-name instances)
                     nil t)))
               (valsi-terminal-agent-get root selected)))
        (let ((default-directory root))
          (valsi-agent "primary" valsi-agent-terminal-backend)))))

(defun valsi-terminal-agent-insert (text &optional name)
  "Insert TEXT into agent NAME's terminal prompt without submitting it."
  (let* (;; Embedded newlines are submission keys in ordinary terminal
         ;; programs.  Flatten at the shared boundary so review-before-submit
         ;; remains true for every backend, not only rich prompt editors.
         (text (string-trim
                (replace-regexp-in-string "[\r\n]+" "  " text)))
         (instance (valsi-terminal-agent--target name))
         (buffer (valsi-terminal-agent-instance-buffer instance)))
    (unless (valsi-terminal-agent--live-p instance)
      (user-error "Agent %s is not running"
                  (valsi-terminal-agent-instance-name instance)))
    (with-current-buffer buffer
      (unless (and (boundp 'eat-terminal) eat-terminal)
        (user-error "Agent buffer is not an active Eat terminal"))
      ;; Bracketed-yank is the terminal-safe equivalent of pasting into the
      ;; CLI's current prompt.  Deliberately send no newline.
      (eat-term-send-string-as-yank eat-terminal (list text)))
    (switch-to-buffer buffer)
    instance))

;;;###autoload
(defun valsi-agent (&optional name backend)
  "Open or start project terminal agent NAME using BACKEND.
NAME defaults to \"primary\" and BACKEND to
`valsi-agent-terminal-backend'.  The CLI runs directly inside Eat."
  (interactive
   (if current-prefix-arg
       (let ((root (valsi-terminal-agent-project-root)))
         (list (valsi-terminal-agent--read-name root)
               (valsi-terminal-agent--read-backend)))
     (list nil nil)))
  (let* ((root (valsi-terminal-agent-project-root))
         (name (or name "primary"))
         (backend (or backend valsi-agent-terminal-backend))
         (instance (or (valsi-terminal-agent-get root name)
                       (valsi-terminal-agent--start root name backend))))
    (switch-to-buffer (valsi-terminal-agent-instance-buffer instance))
    instance))

;;;###autoload
(defun valsi-agent-new (name backend)
  "Start a new named terminal agent NAME using BACKEND."
  (interactive
   (let ((root (valsi-terminal-agent-project-root)))
     (list (valsi-terminal-agent--read-name root "New agent name: ")
           (valsi-terminal-agent--read-backend))))
  (let ((root (valsi-terminal-agent-project-root)))
    (when (valsi-terminal-agent-get root name)
      (user-error "Agent %s is already running in this project" name))
    (valsi-agent name backend)))

;;;###autoload
(defun valsi-agent-switch ()
  "Select and focus a live terminal agent in the current project."
  (interactive)
  (let* ((root (valsi-terminal-agent-project-root))
         (instances
          (seq-filter #'valsi-terminal-agent--live-p
                      (valsi-terminal-agent-list root)))
         (names (mapcar #'valsi-terminal-agent-instance-name instances)))
    (unless names (user-error "No live Valsi agents in this project"))
    (valsi-agent (completing-read "Switch to agent: " names nil t))))

(defun valsi-terminal-agent-focus ()
  "Show the current project's primary terminal as the only window."
  (interactive)
  (let ((instance (valsi-agent)))
    (delete-other-windows)
    (switch-to-buffer (valsi-terminal-agent-instance-buffer instance))))

(defun valsi-terminal-agent-stop (&optional name)
  "Stop project agent NAME after confirmation."
  (interactive)
  (let* ((root (valsi-terminal-agent-project-root))
         (name (or name "primary"))
         (key (valsi-terminal-agent--key root name))
         (instance (gethash key valsi-terminal-agent--instances)))
    (unless instance (user-error "No Valsi agent named %s" name))
    (when (yes-or-no-p (format "Stop agent %s? " name))
      (when-let* ((buffer (valsi-terminal-agent-instance-buffer instance)))
        (when-let* ((process (get-buffer-process buffer)))
          (delete-process process))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (remhash key valsi-terminal-agent--instances))))

(provide 'valsi-terminal-agent)
;;; valsi-terminal-agent.el ends here

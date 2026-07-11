;;; valsi.el --- Grammar-aware views for agent artifacts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; Author: Samuel Schmidt <schmidt.l.samuel@gmail.com>
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1") (eat "0.9.4"))
;; Keywords: convenience, docs, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; URL: https://github.com/s-l-s/valsi

;;; Commentary:

;; Valsi is the reference client of the Agent Artifact Protocol (AAP): it gives
;; agent-facing markdown files -- plan/tasks, instruction (AGENTS/CLAUDE),
;; prompt-files (SKILL), and memory -- grammar-aware views, dedicated
;; dashboards, and per-artifact keybindings, while every file on disk stays
;; ordinary, diffable markdown.
;;
;; This is the CLIENT.  The model + parse + grammar plugins live behind the
;; registry (the server model); here it runs in-process (the drop-in transport
;; the plan permits).  Enable `valsi-artifact-minor-mode' in any markdown buffer
;; -- or turn on `valsi-global-mode' to auto-enable wherever a grammar matches.
;;
;; The buffer stays plain markdown: `valsi-artifact-minor-mode' only layers
;; font-lock + a keymap on top (the minor-mode / liveness invariant).

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)
(require 'valsi-registry)
(require 'valsi-proto)
(require 'valsi-view)
(require 'valsi-graph)
(require 'valsi-plan)
(require 'valsi-instruction)
(require 'valsi-promptfile)
(require 'valsi-memory)
(require 'valsi-changelog)
(require 'valsi-decision)
(require 'valsi-overview)
(require 'valsi-plan-review)
(require 'valsi-plan-agent)
(require 'valsi-terminal-agent)
(require 'valsi-app)
(require 'transient)

;;;; Initialization: register the bundled grammars

(defvar valsi--initialized nil
  "Non-nil once the bundled grammars are registered.")

;;;###autoload
(defun valsi-init ()
  "Register the generic grammar and all bundled artifact grammar plugins."
  (valsi-registry-init-generic)
  (valsi-plan-register)
  (valsi-instruction-register)
  (valsi-promptfile-register)
  (valsi-memory-register)
  (valsi-changelog-register)
  (valsi-decision-register)
  (valsi-overview-register)
  (setq valsi--initialized t))

;;;; The connection (the transport seam)

;; In-process, the "connection" is the proto server itself: `valsi--request'
;; calls `valsi-proto-request' directly, passing elisp values (the plan's "same
;; JSON types, no stdio" transport).  To move the server out-of-process, swap
;; only this function for a `jsonrpc.el' call and (de)serialize with
;; `valsi-node-to-plist' / `valsi-node-from-plist' at the wire -- nothing else in
;; the client changes.

(defun valsi--request (method params)
  "Send AAP request METHOD with PARAMS to the server, returning the response."
  (valsi-proto-request method params))

;;;; Buffer-local model state (the client's view of the server model)

(defvar-local valsi--grammar nil
  "The grammar id the server resolved for the current buffer's document.")

(defvar-local valsi--tree nil
  "Cached tree (root `valsi-node') for the current buffer, in BUFFER coordinates.
Nil means stale; `valsi-tree' refetches it from the server via the proto layer.")

(defvar-local valsi--capabilities nil
  "Advertised action symbols for the current document (the degradation ladder).")

(defun valsi--uri ()
  "Return the document uri for the current buffer."
  (or buffer-file-name (buffer-name)))

(defun valsi--sync (&optional open)
  "Push the buffer's content to the server (didChange, or didOpen when OPEN).
Records the resolved grammar + capabilities.  Marks the local tree stale."
  (unless valsi--initialized (valsi-init))
  (let ((resp (valsi--request (if open 'artifact/didOpen 'artifact/didChange)
                             (list :uri (valsi--uri) :text (buffer-string)))))
    (setq valsi--grammar (plist-get resp :grammar))
    (setq valsi--capabilities (plist-get resp :capabilities))
    (setq valsi--tree nil)
    resp))

(defun valsi-tree ()
  "Return the current buffer's tree in buffer coordinates, fetching if stale.
The server holds the model in document offsets; the client owns the single
offset->buffer-position translation here."
  (unless valsi--grammar (valsi--sync t))
  (or valsi--tree
      (progn
        (valsi--sync)
        (let ((sym (valsi--request 'artifact/symbols (list :uri (valsi--uri)))))
          (setq valsi--tree
                (when sym
                  ;; Deep-copy so shifting never mutates the server's tree, then
                  ;; translate document offsets to this buffer's positions.
                  (let ((local (valsi-node-deep-copy sym)))
                    (valsi-node-shift local (point-min))
                    local)))))))

;; Backwards-compatible accessor name used by earlier client code.
(defalias 'valsi-current-tree #'valsi-tree)

(defun valsi-refresh ()
  "Resync the buffer with the server and refetch its tree."
  (interactive)
  (valsi--sync (null valsi--grammar))
  (valsi-tree)
  (when (called-interactively-p 'interactive)
    (message "Valsi: %s grammar, %d nodes, caps: %s"
             valsi--grammar
             (let ((n 0)) (when valsi--tree
                            (valsi-node-walk valsi--tree (lambda (_ _d) (cl-incf n))))
                  n)
             valsi--capabilities))
  valsi--tree)

;;;; Generic action dispatch (client -> active grammar's command)

(defun valsi--dispatch (action)
  "Invoke the ACTION command advertised by the active grammar."
  (unless valsi--grammar (valsi-refresh))
  (let ((cmd (valsi-registry-command valsi--grammar action)))
    (if (and cmd (fboundp cmd))
        (call-interactively cmd)
      (message "Valsi: `%s' not supported by the %s grammar"
               action (or valsi--grammar 'generic)))))

(defmacro valsi--defaction (name action doc)
  "Define command NAME dispatching ACTION to the active grammar, with DOC."
  `(defun ,name ()
     ,doc
     (interactive)
     (valsi--dispatch ',action)))

(valsi--defaction valsi-next next "Move to the next artifact element.")
(valsi--defaction valsi-previous prev "Move to the previous artifact element.")
(valsi--defaction valsi-goto goto "Jump to an element by id/name.")
(valsi--defaction valsi-toggle toggle "Toggle/cycle the element at point.")
(valsi--defaction valsi-info info "Echo info about the element at point.")
(valsi--defaction valsi-progress progress "Report progress for this artifact.")
(valsi--defaction valsi-occur occur-state "Occur over elements by state.")
(valsi--defaction valsi-next-actionable next-actionable
                 "Jump to the next actionable task.")
(valsi--defaction valsi-lint lint "Lint / validate this artifact.")
(valsi--defaction valsi-follow follow "Follow the reference at point.")
(valsi--defaction valsi-dashboard dashboard "Open this family's dashboard view.")
(valsi--defaction valsi-detect detect "Report the detected dialect.")

(defun valsi-describe-grammar ()
  "Describe the grammar owning this buffer and its advertised capabilities."
  (interactive)
  (unless valsi--grammar (valsi-refresh))
  (let ((d (valsi-registry-describe valsi--grammar)))
    (message "Valsi grammar: %s (%s, tier: %s) — caps: %s"
             (plist-get d :name) valsi--grammar
             (plist-get d :evidence) valsi--capabilities)))

;;;; Keymap

(defvar valsi-artifact-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c n n") #'valsi-next)
    (define-key map (kbd "C-c n p") #'valsi-previous)
    (define-key map (kbd "C-c n g") #'valsi-goto)
    (define-key map (kbd "C-c n t") #'valsi-toggle)
    (define-key map (kbd "C-c n i") #'valsi-info)
    (define-key map (kbd "C-c n %") #'valsi-progress)
    (define-key map (kbd "C-c n o") #'valsi-occur)
    (define-key map (kbd "C-c n a") #'valsi-next-actionable)
    (define-key map (kbd "C-c n l") #'valsi-lint)
    (define-key map (kbd "C-c n RET") #'valsi-follow)
    (define-key map (kbd "C-c n d") #'valsi-dashboard)
    (define-key map (kbd "C-c n D") #'valsi-detect)
    (define-key map (kbd "C-c n r") #'valsi-refresh)
    (define-key map (kbd "C-c n G") #'valsi-graph)
    (define-key map (kbd "C-c n c") #'valsi)
    (define-key map (kbd "C-c n @") #'valsi-app-handoff)
    (define-key map (kbd "C-c n ?") #'valsi-describe-grammar)
    (define-key map (kbd "C-c n m") #'valsi-menu)
    map)
  "Keymap for `valsi-artifact-minor-mode'.")

;;;; Header line

(defun valsi--header-line ()
  "Return the header-line string for the current artifact buffer."
  (let ((d (and valsi--grammar (valsi-registry-describe valsi--grammar))))
    (concat
     (propertize " Valsi " 'face 'valsi-id-face)
     (propertize (format "%s " (or (plist-get d :name) "generic"))
                 'face 'bold)
     (propertize (format "[%s] " (or (plist-get d :evidence) "-"))
                 'face 'valsi-meta-face)
     (propertize (format "· C-c n m for menu · caps: %s"
                         (or valsi--capabilities "outline"))
                 'face 'shadow))))

;;;; Minor mode

(defun valsi--install-font-lock ()
  "Install the active grammar's font-lock keywords."
  (let* ((spec (valsi-registry-get valsi--grammar))
         (kw (plist-get spec :font-lock)))
    (valsi-view-set-font-lock
     (if (functionp kw) (funcall kw (current-buffer)) kw))))

;;;###autoload
(define-minor-mode valsi-artifact-minor-mode
  "Grammar-aware views + keybindings for agent artifacts.
The underlying file stays ordinary markdown; this only layers font-lock and
a keymap (\\{valsi-artifact-mode-map})."
  :lighter " Valsi"
  :keymap valsi-artifact-mode-map
  (if valsi-artifact-minor-mode
      (progn
        (unless valsi--initialized (valsi-init))
        (valsi--sync t)                  ; artifact/didOpen
        (valsi-tree)                     ; fetch symbols -> local tree
        (valsi--install-font-lock)
        (setq-local header-line-format '(:eval (valsi--header-line)))
        (add-hook 'after-change-functions #'valsi--after-change nil t)
        (add-hook 'after-save-hook #'valsi-refresh nil t))
    (valsi--request 'artifact/didClose (list :uri (valsi--uri)))
    (valsi-view-set-font-lock nil)
    (setq-local header-line-format nil)
    (remove-hook 'after-change-functions #'valsi--after-change t)
    (remove-hook 'after-save-hook #'valsi-refresh t)
    (when font-lock-mode (font-lock-flush) (font-lock-ensure))))

(defun valsi--after-change (&rest _)
  "Mark the local tree stale after an edit; the next `valsi-tree' resyncs."
  (setq valsi--tree nil))

;;;; Transient menu (discoverable entry point)

(transient-define-prefix valsi-menu ()
  "Valsi artifact command menu."
  [["Navigate"
    ("n" "next" valsi-next)
    ("p" "previous" valsi-previous)
    ("g" "goto id/name" valsi-goto)
    ("a" "next actionable" valsi-next-actionable)
    ("RET" "follow ref" valsi-follow)]
   ["Act"
    ("t" "toggle/cycle" valsi-toggle)
    ("i" "info at point" valsi-info)
    ("%" "progress" valsi-progress)
    ("o" "occur by state" valsi-occur)
    ("l" "lint/validate" valsi-lint)]
   ["Views"
    ("c" "project hub" valsi)
    ("A" "agent terminal" valsi-agent)
    ("@" "agent + artifacts" valsi-agent-with-artifacts)
    ("h" "reference to agent" valsi-app-handoff)
    ("d" "family dashboard" valsi-dashboard)
    ("G" "cross-artifact graph" valsi-graph)
    ("D" "detect dialect" valsi-detect)
    ("?" "describe grammar" valsi-describe-grammar)
    ("r" "reparse" valsi-refresh)]])

;;;; Global auto-enable

(defun valsi--maybe-enable ()
  "Enable `valsi-artifact-minor-mode' if a grammar matches this buffer."
  (unless valsi--initialized (valsi-init))
  (when (and (derived-mode-p 'text-mode 'markdown-mode 'fundamental-mode)
             buffer-file-name
             (string-match-p "\\.\\(md\\|mdc\\|markdown\\)\\'" buffer-file-name)
             (not (eq (valsi-registry-detect buffer-file-name (buffer-string))
                      'generic)))
    (valsi-artifact-minor-mode 1)))

;;;###autoload
(define-globalized-minor-mode valsi-global-mode
  valsi-artifact-minor-mode valsi--maybe-enable
  :group 'valsi)

(provide 'valsi)
;;; valsi.el ends here

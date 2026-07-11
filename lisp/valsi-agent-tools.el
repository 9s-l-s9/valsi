;;; valsi-agent-tools.el --- Typed tool registry for the Valsi agent core -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A tool is a typed schema plus an executor returning a structured result
;; (tau's `AgentTool'/`AgentToolResult', research/03 Pattern 2).  The
;; `ok'/`error' split lets the loop feed failures back to the model cleanly.
;;
;; Every mutating tool carries a CONFIRM gate -- the "control over delegation"
;; invariant.  Tools are structurally convertible to a `gptel-tool' but depend
;; on nothing external.

;;; Code:

(require 'cl-lib)
(require 'valsi-agent-provider)

;;;; Tool + result structs

(cl-defstruct (valsi-agent-tool (:constructor valsi-agent-tool-create))
  "A typed tool.
NAME is a string; DESCRIPTION prompts the model; ARGS is a JSON-Schema plist for
the input object; EXECUTOR is a function of an args plist returning a
`valsi-agent-tool-result'; CATEGORY is a grouping symbol; CONFIRM gates execution
\(nil = auto, t = always ask, or a predicate of args deciding when to ask)."
  name description args executor (category 'general) (confirm nil))

(cl-defstruct (valsi-agent-tool-result (:constructor valsi-agent-tool-result-create))
  "A structured tool outcome (tau model).
OK is the success flag; CONTENT is the string fed back to the model; DATA is any
structured payload for callers; ERROR is a message when OK is nil."
  (ok t) (content "") (data nil) (error nil))

;;;; Registry

(defvar valsi-agent-tools--registry (make-hash-table :test 'equal)
  "Registered tools keyed by name string.")

(defun valsi-agent-register-tool (tool)
  "Register TOOL, replacing any tool of the same name, and return TOOL."
  (puthash (valsi-agent-tool-name tool) tool valsi-agent-tools--registry)
  tool)

(defun valsi-agent-get-tool (name)
  "Return the registered tool named NAME, or nil."
  (gethash name valsi-agent-tools--registry))

(defun valsi-agent-tools (&optional names)
  "Return registered tools; if NAMES (a list of strings) is given, only those."
  (if names
      (delq nil (mapcar #'valsi-agent-get-tool names))
    (let (out) (maphash (lambda (_k v) (push v out)) valsi-agent-tools--registry)
         (nreverse out))))

(defun valsi-agent-tool-to-schema (tool)
  "Return TOOL as a provider tool schema plist (Anthropic tool shape)."
  (list :name (valsi-agent-tool-name tool)
        :description (or (valsi-agent-tool-description tool) "")
        :input_schema (or (valsi-agent-tool-args tool)
                          (list :type "object" :properties (list)))))

;;;; Scoping (control over delegation -- per-dispatch allow-lists)

(defvar valsi-agent-allowed-tools :unrestricted
  "Permitted tool names for the current dispatch.
The sentinel `:unrestricted' applies only outside `valsi-agent-scope'; within a
scope, nil means no tools are permitted.")

(defvar valsi-agent-allowed-files :unrestricted
  "Permitted file paths for the current dispatch.
The sentinel `:unrestricted' is used only outside an explicit
`valsi-agent-scope'.  Within a scope, nil means no files are permitted.")

(defvar valsi-agent-dry-run nil
  "When non-nil, mutating tools report intended changes without writing.")

(defun valsi-agent-file-allowed-p (path)
  "Return non-nil if PATH is permitted by `valsi-agent-allowed-files'."
  (and path
       (or (eq valsi-agent-allowed-files :unrestricted)
           (let ((abs (valsi-agent--canonical-path path)))
             (cl-some (lambda (allowed)
                        (string= (valsi-agent--canonical-path allowed) abs))
                      valsi-agent-allowed-files)))))

(defun valsi-agent--canonical-path (path)
  "Return a canonical absolute form of PATH for scope comparisons."
  (let ((abs (expand-file-name path)))
    (if (file-exists-p abs) (file-truename abs) abs)))

;;;; Confirmation gate (control over delegation)

(defvar valsi-agent-confirm-function #'y-or-n-p
  "Function to confirm a gated tool call; takes a prompt, returns boolean.")

(defvar valsi-agent-auto-approve nil
  "When non-nil, gated tool calls run without prompting (tests, dry batch runs).
The scoping layer (`valsi-agent-scope') binds this per dispatch.")

(defun valsi-agent--needs-confirm-p (tool args)
  "Return non-nil if TOOL requires confirmation for ARGS."
  (let ((c (valsi-agent-tool-confirm tool)))
    (cond ((functionp c) (funcall c args))
          (t c))))

(defun valsi-agent--confirm (tool args)
  "Return non-nil if the gated TOOL call with ARGS is approved."
  (or valsi-agent-auto-approve
      (funcall valsi-agent-confirm-function
               (format "Valsi: run tool %s %S? " (valsi-agent-tool-name tool) args))))

;;;; Execution

(defun valsi-agent-execute-tool (tool args)
  "Execute TOOL with ARGS, honoring its confirm gate.
Returns a `valsi-agent-tool-result'.  A declined confirmation or a signalled
error becomes a non-OK result (never a thrown error), so the loop keeps going."
  (condition-case err
      (cond
       ((and (not (eq valsi-agent-allowed-tools :unrestricted))
             (not (member (valsi-agent-tool-name tool) valsi-agent-allowed-tools)))
        (valsi-agent-tool-result-create
         :ok nil :error "tool not in scope"
         :content (format "Tool %s is not permitted for this dispatch."
                          (valsi-agent-tool-name tool))))
       ((and (valsi-agent--needs-confirm-p tool args)
             (not (valsi-agent--confirm tool args)))
        (valsi-agent-tool-result-create
         :ok nil :error "declined by user"
         :content "Tool call declined by the user."))
       (t (funcall (valsi-agent-tool-executor tool) args)))
    (error
     (valsi-agent-tool-result-create
      :ok nil :error (error-message-string err)
      :content (format "Tool error: %s" (error-message-string err))))))

;;;; Built-in tools (read-file / list-dir / grep / apply-edit)

(defun valsi-agent--read-file (args)
  "Executor: return the contents of file :path in ARGS."
  (let ((path (plist-get args :path)))
    (if (and path (not (valsi-agent-file-allowed-p path)))
        (valsi-agent-tool-result-create
         :ok nil :error "file not in scope"
         :content (format "%s is outside the dispatch scope." path))
    (if (and path (file-readable-p path))
        (valsi-agent-tool-result-create
         :ok t :content (with-temp-buffer (insert-file-contents path)
                                          (buffer-string)))
      (valsi-agent-tool-result-create
       :ok nil :error (format "cannot read %s" path)
       :content (format "No readable file at %s" path))))))

(defun valsi-agent--list-dir (args)
  "Executor: list the entries of directory :path in ARGS."
  (let ((path (or (plist-get args :path) default-directory)))
    (cond
     ((not (valsi-agent-file-allowed-p path))
      (valsi-agent-tool-result-create
       :ok nil :error "directory not in scope"
       :content (format "%s is outside the dispatch scope." path)))
     ((file-directory-p path)
      (valsi-agent-tool-result-create
       :ok t :content (mapconcat #'identity
                                 (directory-files path nil "\\`[^.]") "\n")))
     (t
      (valsi-agent-tool-result-create
       :ok nil :error (format "not a directory: %s" path)
       :content (format "%s is not a directory" path))))))

(defun valsi-agent--grep (args)
  "Executor: return lines in file :path matching regexp :pattern in ARGS."
  (let ((pattern (plist-get args :pattern))
        (path (plist-get args :path)))
    (cond
     ((and path (not (valsi-agent-file-allowed-p path)))
      (valsi-agent-tool-result-create
       :ok nil :error "file not in scope"
       :content (format "%s is outside the dispatch scope." path)))
     ((and pattern path (file-readable-p path))
        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (let (hits (n 0))
            (while (not (eobp))
              (cl-incf n)
              (let ((line (buffer-substring-no-properties
                           (line-beginning-position) (line-end-position))))
                (when (string-match-p pattern line)
                  (push (format "%d:%s" n line) hits)))
              (forward-line 1))
            (valsi-agent-tool-result-create
             :ok t :content (mapconcat #'identity (nreverse hits) "\n")
             :data (length hits)))))
     (t
      (valsi-agent-tool-result-create
       :ok nil :error "grep: missing pattern/path or unreadable file"
       :content "grep needs :pattern and a readable :path")))))

(defun valsi-agent--apply-edit (args)
  "Executor: replace the first :old with :new in file :path (ARGS).
Mutating -- gated by CONFIRM at the tool level."
  (let ((path (plist-get args :path))
        (old (plist-get args :old))
        (new (plist-get args :new)))
    (cond
     ((and path (not (valsi-agent-file-allowed-p path)))
      (valsi-agent-tool-result-create
       :ok nil :error "file not in scope"
       :content (format "%s is outside the dispatch scope." path)))
     ((not (and path old (file-writable-p path)))
      (valsi-agent-tool-result-create
       :ok nil :error "apply-edit: missing args or unwritable file"
       :content "apply-edit needs :path :old :new and a writable file"))
     (t
      (with-temp-buffer
        (insert-file-contents path)
        (goto-char (point-min))
        (if (search-forward old nil t)
            (progn
              (replace-match (or new "") t t)
              (if valsi-agent-dry-run
                  (valsi-agent-tool-result-create
                   :ok t :content (format "[dry-run] would edit %s" path))
                (write-region (point-min) (point-max) path)
                (valsi-agent-tool-result-create
                 :ok t :content (format "Edited %s" path))))
          (valsi-agent-tool-result-create
           :ok nil :error "apply-edit: :old not found"
           :content (format "Text to replace not found in %s" path))))))))

(defun valsi-agent-register-builtin-tools ()
  "Register and return the built-in file tools."
  (mapcar
   #'valsi-agent-register-tool
   (list
    (valsi-agent-tool-create
     :name "read_file" :category 'read
     :description "Read and return the full contents of a file."
     :args '(:type "object"
             :properties (:path (:type "string" :description "File path"))
             :required ["path"])
     :executor #'valsi-agent--read-file)
    (valsi-agent-tool-create
     :name "list_dir" :category 'read
     :description "List the non-hidden entries of a directory."
     :args '(:type "object"
             :properties (:path (:type "string" :description "Directory path")))
     :executor #'valsi-agent--list-dir)
    (valsi-agent-tool-create
     :name "grep" :category 'read
     :description "Return lines of a file matching a regexp, prefixed by line number."
     :args '(:type "object"
             :properties (:pattern (:type "string") :path (:type "string"))
             :required ["pattern" "path"])
     :executor #'valsi-agent--grep)
    (valsi-agent-tool-create
     :name "apply_edit" :category 'write :confirm t
     :description "Replace the first occurrence of :old with :new in a file."
     :args '(:type "object"
             :properties (:path (:type "string") :old (:type "string")
                          :new (:type "string"))
             :required ["path" "old" "new"])
     :executor #'valsi-agent--apply-edit))))

(provide 'valsi-agent-tools)
;;; valsi-agent-tools.el ends here

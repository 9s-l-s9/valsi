;;; valsi-registry.el --- Grammar-plugin registry for Valsi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The grammar-plugin registry -- the AAP `grammar/register' / `grammar/reload'
;; / `grammar/describe' surface, realized in-process.  Each grammar declares:
;;
;;   :id          symbol, unique
;;   :name        human label
;;   :evidence    standardized | converging | emergent
;;   :match       (function BUFFER) -> score (higher wins), for auto-detect
;;   :parse       (function BUFFER) -> root `valsi-node'
;;   :font-lock   font-lock keyword list (or function BUFFER -> keywords)
;;   :capabilities  list of action symbols, OR (function ROOT) -> list
;;                  (the degradation ladder, advertised per document)
;;   :commands    alist (ACTION . COMMAND-SYMBOL) dispatched by the client
;;
;; Registering or reloading a grammar takes effect immediately -- no restart
;; (the liveness / hot-reload invariant).

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)

(defvar valsi-registry--table (make-hash-table :test 'eq)
  "Map of grammar id (symbol) -> grammar spec plist.")

(defvar valsi-registry-hook nil
  "Run with the grammar id after a grammar is (re)registered.")

;;;; Registration (grammar/register, grammar/reload)

(defun valsi-registry-register (spec)
  "Register grammar SPEC (a plist).  Overwrites any grammar with the same id.
Takes effect immediately (hot-reload); returns the id."
  (let ((id (plist-get spec :id)))
    (unless id (error "Grammar spec has no :id"))
    (puthash id spec valsi-registry--table)
    (run-hook-with-args 'valsi-registry-hook id)
    id))

(defalias 'valsi-registry-reload #'valsi-registry-register
  "Reload a grammar SPEC in place (alias of `valsi-registry-register').")

(defun valsi-registry-register-declaration (declaration)
  "Compile and register JSON-safe grammar DECLARATION.
Unlike the internal plugin API accepted by `valsi-registry-register',
DECLARATION contains data rather than executable functions.  Its `:match'
object may contain `:uriSuffix', `:uriRegexp', `:textRegexp', and `:score'.
Its `:recognizers' array contains line recognizers with `:type', `:regexp',
optional `:confidence', and optional capture-index `:properties'."
  (let* ((id (valsi-registry--declaration-symbol
              (plist-get declaration :id) "grammar id"))
         (evidence (valsi-registry--declaration-symbol
                    (or (plist-get declaration :evidence) "emergent")
                    "evidence"))
         (match-decl (plist-get declaration :match))
         (recognizers (append (plist-get declaration :recognizers) nil))
         (caps (mapcar (lambda (cap)
                         (valsi-registry--declaration-symbol cap "capability"))
                       (append (plist-get declaration :capabilities) nil)))
         (root-type (valsi-registry--declaration-symbol
                     (or (plist-get declaration :rootType) "document")
                     "root type")))
    (unless (memq evidence '(standardized converging emergent))
      (error "Grammar declaration has invalid evidence tier: %S" evidence))
    (valsi-registry--validate-declaration match-decl recognizers)
    (valsi-registry-register
     (list :id id
           :name (or (plist-get declaration :name) (symbol-name id))
           :evidence evidence
           :match (valsi-registry--declarative-matcher match-decl)
           :parse (valsi-registry--declarative-parser id root-type recognizers)
           :capabilities caps
           :commands nil
           :declaration declaration))))

(defun valsi-registry--declaration-symbol (value field)
  "Coerce string or symbol VALUE to a symbol, identifying invalid FIELD."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))
        (t (error "Grammar declaration has invalid %s: %S" field value))))

(defun valsi-registry--validate-regexp (regexp field)
  "Validate REGEXP from FIELD, signaling a useful registration error."
  (when regexp
    (unless (stringp regexp)
      (error "Grammar declaration %s must be a string" field))
    (condition-case err
        (string-match-p regexp "")
      (invalid-regexp
       (error "Grammar declaration has invalid %s: %s"
              field (error-message-string err))))))

(defun valsi-registry--validate-declaration (match-decl recognizers)
  "Validate declarative MATCH-DECL and line RECOGNIZERS."
  (unless (listp match-decl)
    (error "Grammar declaration :match must be an object"))
  (unless (cl-some (lambda (key) (plist-get match-decl key))
                   '(:uriSuffix :uriRegexp :textRegexp))
    (error "Grammar declaration :match needs a URI or text predicate"))
  (let ((suffix (plist-get match-decl :uriSuffix)))
    (when (and suffix (not (stringp suffix)))
      (error "Grammar declaration :match.uriSuffix must be a string")))
  (valsi-registry--validate-regexp (plist-get match-decl :uriRegexp)
                                  ":match.uriRegexp")
  (valsi-registry--validate-regexp (plist-get match-decl :textRegexp)
                                  ":match.textRegexp")
  (unless (numberp (or (plist-get match-decl :score) 1))
    (error "Grammar declaration :match.score must be a number"))
  (dolist (recognizer recognizers)
    (valsi-registry--declaration-symbol (plist-get recognizer :type)
                                       "recognizer type")
    (unless (stringp (plist-get recognizer :regexp))
      (error "Grammar declaration recognizers need a regexp string"))
    (valsi-registry--validate-regexp (plist-get recognizer :regexp)
                                    ":recognizers[].regexp")
    (let ((confidence
           (valsi-registry--declaration-symbol
            (or (plist-get recognizer :confidence) "exact")
            "recognizer confidence"))
          (properties (plist-get recognizer :properties)))
      (unless (memq confidence '(exact loose))
        (error "Grammar recognizer confidence must be exact or loose"))
      (while properties
        (unless (and (keywordp (car properties))
                     (integerp (cadr properties))
                     (>= (cadr properties) 0))
          (error "Grammar recognizer properties must map names to capture indices"))
        (setq properties (cddr properties)))))
  t)

(defun valsi-registry--declarative-matcher (declaration)
  "Return a pure matcher function compiled from match DECLARATION."
  (let ((suffix (plist-get declaration :uriSuffix))
        (uri-re (plist-get declaration :uriRegexp))
        (text-re (plist-get declaration :textRegexp))
        (score (or (plist-get declaration :score) 1)))
    (lambda (uri text)
      (if (or (and suffix (string-suffix-p suffix (or uri "")))
              (and uri-re (string-match-p uri-re (or uri "")))
              (and text-re (string-match-p text-re (or text ""))))
          score
        0))))

(defun valsi-registry--declarative-parser (grammar-id root-type recognizers)
  "Return a parser for GRAMMAR-ID, ROOT-TYPE, and line RECOGNIZERS."
  (lambda (content)
    (valsi-parse-in-content
     content
     (lambda ()
       (let ((root (valsi-node-create :type root-type
                                     :beg (point-min) :end (point-max)
                                     :recognizer grammar-id)))
         (dolist (line (valsi-parse-lines (current-buffer)))
           (dolist (recognizer recognizers)
             (let ((regexp (plist-get recognizer :regexp))
                   (text (valsi-line-text line)))
               (when (and regexp (string-match regexp text))
                 (valsi-node-add-child
                  root
                  (valsi-node-create
                   :type (valsi-registry--declaration-symbol
                          (plist-get recognizer :type) "recognizer type")
                   :beg (valsi-line-beg line) :end (valsi-line-end line)
                   :confidence
                   (valsi-registry--declaration-symbol
                    (or (plist-get recognizer :confidence) "exact")
                    "recognizer confidence")
                   :recognizer grammar-id
                   :props (valsi-registry--declarative-props
                           (plist-get recognizer :properties) text)))))))
         root)))))

(defun valsi-registry--declarative-props (properties text)
  "Extract capture-index PROPERTIES from the current match against TEXT."
  (let (out)
    (while properties
      (let ((key (car properties))
            (capture (cadr properties)))
        (when (and (integerp capture) (match-beginning capture))
          (setq out (plist-put out key (match-string capture text)))))
      (setq properties (cddr properties)))
    out))

(defun valsi-registry-unregister (id)
  "Remove grammar ID from the registry."
  (remhash id valsi-registry--table))

(defun valsi-registry-get (id)
  "Return the spec for grammar ID, or nil."
  (gethash id valsi-registry--table))

(defun valsi-registry-all ()
  "Return a list of all registered grammar ids."
  (let (ids) (maphash (lambda (k _v) (push k ids)) valsi-registry--table)
       (nreverse ids)))

(defun valsi-registry-describe (id)
  "Return a human-readable description plist for grammar ID (grammar/describe)."
  (let ((s (valsi-registry-get id)))
    (when s
      (list :id id
            :name (plist-get s :name)
            :evidence (plist-get s :evidence)
            :commands (mapcar #'car (plist-get s :commands))))))

;;;; Detection (which grammar owns this document)

(defun valsi-registry-detect (uri text)
  "Return the id of the best-matching grammar for URI + TEXT.
URI is a document identifier (path/name) and TEXT is its content.  Detection
is a pure function of these two -- no live buffer.  Falls back to `generic'
when nothing scores above zero."
  (let ((best 'generic) (best-score 0))
    (dolist (id (valsi-registry-all))
      (let* ((spec (valsi-registry-get id))
             (match (plist-get spec :match))
             (score (if match
                        (condition-case nil
                            (or (funcall match uri text) 0)
                          (error 0))
                      0)))
        (when (> score best-score)
          (setq best id best-score score))))
    best))

;;;; Parse + capability advertisement

(defun valsi-registry-parse-content (id content)
  "Parse CONTENT (a string) with grammar ID, returning the offset-based root.
The result is buffer-independent (0-based offsets into CONTENT)."
  (let* ((spec (valsi-registry-get id))
         (parse (plist-get spec :parse)))
    (if parse
        (funcall parse content)
      (valsi-registry--parse-generic content))))

(defun valsi-registry-capabilities (id root)
  "Return the list of action symbols grammar ID supports for ROOT.
This is the per-document degradation-ladder advertisement."
  (let* ((spec (valsi-registry-get id))
         (caps (plist-get spec :capabilities)))
    (cond ((functionp caps) (funcall caps root))
          ((listp caps) caps)
          (t nil))))

(defun valsi-registry-command (id action)
  "Return the command symbol for ACTION in grammar ID, or nil."
  (let ((spec (valsi-registry-get id)))
    (cdr (assq action (plist-get spec :commands)))))

;;;; The generic-markdown grammar (rung 1: outline / narrowing only)

(defun valsi-registry--parse-generic (content)
  "Parse CONTENT into a heading outline tree (rung-1 generic markdown)."
  (valsi-parse-in-content
   content
   (lambda ()
     (let ((root (valsi-node-create :type 'document
                                   :beg (point-min) :end (point-max)
                                   :recognizer 'generic))
           (stack nil))                  ; list of (level . node)
       (dolist (line (valsi-parse-lines (current-buffer)))
         (let ((h (valsi-parse-heading (valsi-line-text line))))
           (if h
               (let ((node (valsi-node-create
                            :type 'heading
                            :beg (valsi-line-beg line) :end (valsi-line-end line)
                            :recognizer 'generic
                            :props (list :level (car h) :title (cdr h)))))
                 (while (and stack (>= (caar stack) (car h)))
                   (pop stack))
                 (if stack
                     (valsi-node-add-child (cdar stack) node)
                   (valsi-node-add-child root node))
                 (push (cons (car h) node) stack)))))
       root))))

(defun valsi-registry-init-generic ()
  "Register the fallback generic-markdown grammar."
  (valsi-registry-register
   (list :id 'generic
         :name "Generic Markdown"
         :evidence 'standardized
         :match (lambda (_uri _text) 0)
         :parse #'valsi-registry--parse-generic
         :capabilities '(outline narrow)
         :commands nil)))

;; The bundled grammar plugins require this file, so they are loaded at
;; runtime here and only declared for the byte-compiler.
(declare-function valsi-plan-register "valsi-plan")
(declare-function valsi-instruction-register "valsi-instruction")
(declare-function valsi-promptfile-register "valsi-promptfile")
(declare-function valsi-memory-register "valsi-memory")
(declare-function valsi-changelog-register "valsi-changelog")
(declare-function valsi-decision-register "valsi-decision")
(declare-function valsi-overview-register "valsi-overview")

(defun valsi-registry-register-bundled ()
  "Load and register the generic grammar and all bundled grammar plugins.
The single registration site shared by the in-process client
\(`valsi-init') and the standalone server (`valsi-server-init')."
  (dolist (feature '(valsi-plan valsi-instruction valsi-promptfile valsi-memory
                     valsi-changelog valsi-decision valsi-overview))
    (require feature))
  (valsi-registry-init-generic)
  (valsi-plan-register)
  (valsi-instruction-register)
  (valsi-promptfile-register)
  (valsi-memory-register)
  (valsi-changelog-register)
  (valsi-decision-register)
  (valsi-overview-register))

(provide 'valsi-registry)
;;; valsi-registry.el ends here

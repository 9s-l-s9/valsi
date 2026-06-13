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

(provide 'valsi-registry)
;;; valsi-registry.el ends here

;;; valsi-proto.el --- AAP request layer + document store -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The Agent Artifact Protocol boundary, realized as an in-process request
;; handler.  This is the *server*: it owns a store of open documents (content +
;; version + parsed offset tree + resolved grammar + advertised capabilities)
;; and knows nothing about the client's buffers, points, or windows.
;;
;; Every interaction crosses `valsi-proto-request' -- a single JSON-RPC-shaped
;; dispatch (METHOD + PARAMS plist -> response plist).  In-process it is called
;; directly and passes elisp values (the plan's "same JSON types, no stdio"
;; transport); a stdio `jsonrpc.el' transport would wrap exactly this function,
;; serializing PARAMS/response with `valsi-node-to-plist' / `valsi-node-from-plist'
;; at the wire.  `valsi-proto-json-request' performs that JSON-safe conversion;
;; nothing above this layer touches a grammar's internals.
;;
;; Methods:
;;   initialize                 -> capabilities (advertised methods)
;;   grammar/register  {spec}   -> id     (hot-reload; re-resolves open docs)
;;   grammar/describe  {id}     -> plist
;;   grammar/list               -> ids
;;   grammar/detect    {uri text} -> id
;;   artifact/didOpen  {uri text} -> {uri grammar capabilities version}
;;   artifact/didChange {uri text} -> {uri grammar capabilities version}
;;   artifact/didClose {uri}    -> {uri}
;;   artifact/symbols  {uri}    -> root node (offset coordinates) | nil
;;   artifact/capabilities {uri} -> capability list
;;   artifact/planContext {uri taskId} -> task context bundle | nil

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-registry)

(declare-function valsi-plan-context-bundle "valsi-plan-agent" (root task))

(cl-defstruct (valsi-proto-doc (:constructor valsi-proto-doc-create))
  "A server-held document.  TREE is in 0-based content offsets."
  uri text (version 0) grammar tree caps)

(defvar valsi-proto--docs (make-hash-table :test 'equal)
  "Map of document uri -> `valsi-proto-doc'.")

(defconst valsi-proto-methods
  '(initialize grammar/register grammar/describe grammar/list grammar/detect
    artifact/didOpen artifact/didChange artifact/didClose
    artifact/symbols artifact/capabilities artifact/planContext)
  "The methods this server advertises.")

;;;; Dispatch

(defun valsi-proto-request (method params)
  "Handle an AAP request: METHOD (symbol) with PARAMS (plist) -> response plist.
This is the native in-process seam.  A wire transport wraps
`valsi-proto-json-request' instead."
  (pcase method
    ('initialize
     (list :capabilities (mapcar #'symbol-name valsi-proto-methods)))
    ('grammar/register
     (list :id (valsi-proto--register (plist-get params :spec))))
    ('grammar/describe
     (valsi-registry-describe (plist-get params :id)))
    ('grammar/list
     (list :grammars (valsi-registry-all)))
    ('grammar/detect
     (list :id (valsi-registry-detect (plist-get params :uri)
                                     (plist-get params :text))))
    ('artifact/didOpen
     (valsi-proto--sync (plist-get params :uri) (plist-get params :text)))
    ('artifact/didChange
     (valsi-proto--sync (plist-get params :uri) (plist-get params :text)))
    ('artifact/didClose
     (remhash (plist-get params :uri) valsi-proto--docs)
     (list :uri (plist-get params :uri)))
    ('artifact/symbols
     (let ((doc (gethash (plist-get params :uri) valsi-proto--docs)))
       (and doc (valsi-proto-doc-tree doc))))
    ('artifact/capabilities
     (let ((doc (gethash (plist-get params :uri) valsi-proto--docs)))
       (list :capabilities (and doc (valsi-proto-doc-caps doc)))))
    ('artifact/planContext
     (valsi-proto--plan-context (plist-get params :uri)
                               (plist-get params :taskId)))
    (_ (list :error (format "unknown method: %s" method)))))

(defun valsi-proto-json-request (method params)
  "Handle wire METHOD and PARAMS, returning a JSON-serializable value.
METHOD may be a string or symbol.  This adapter is the boundary used by a
JSON-RPC transport; the in-process client continues to use
`valsi-proto-request' and its native node objects."
  (let* ((method-symbol (if (symbolp method) method (intern method)))
         (response (valsi-proto-request method-symbol params)))
    (cond
     ((and (memq method-symbol '(artifact/symbols artifact/planContext))
           (null response))
      :null)
     ((eq method-symbol 'artifact/planContext)
      (valsi-proto--json-plan-context response))
     (t (valsi-proto--jsonify response)))))

(defun valsi-proto--json-plan-context (context)
  "Convert plan CONTEXT to JSON while preserving its collection fields."
  (let ((out (valsi-proto--jsonify context)))
    (unless (plist-get context :group)
      (setq out (plist-put out :group :null)))
    (dolist (key '(:files :deps :traces :steps))
      (setq out
            (plist-put out key
                       (vconcat (or (plist-get context key) nil)))))
    out))

(defun valsi-proto--jsonify (value)
  "Recursively convert native protocol VALUE to JSON-ready data."
  (cond
   ((valsi-node-p value) (valsi-proto--jsonify (valsi-node-to-plist value)))
   ((null value) nil)
   ((or (stringp value) (numberp value) (eq value t)) value)
   ((memq value '(:null :json-null)) :null)
   ((memq value '(:false :json-false)) :false)
   ((symbolp value) (symbol-name value))
   ((vectorp value) (vconcat (mapcar #'valsi-proto--jsonify value)))
   ((and (listp value) (valsi-proto--plist-p value))
    (let (out)
      (while value
        (setq out (plist-put out (car value)
                             (valsi-proto--jsonify (cadr value))))
        (setq value (cddr value)))
      out))
   ((listp value) (vconcat (mapcar #'valsi-proto--jsonify value)))
   (t (error "AAP value is not JSON-serializable: %S" value))))

(defun valsi-proto--plist-p (value)
  "Return non-nil when VALUE is a proper keyword-keyed plist."
  (and value
       (let ((tail value) (valid t))
         (while (and valid (consp tail))
           (setq valid (and (keywordp (car tail)) (consp (cdr tail))))
           (setq tail (cddr tail)))
         (and valid (null tail)))))

;;;; Server-side operations

(defun valsi-proto--sync (uri text)
  "Open-or-update document URI with TEXT: detect grammar, parse, cache."
  (let* ((existing (gethash uri valsi-proto--docs))
         (grammar (valsi-registry-detect uri text))
         (tree (valsi-registry-parse-content grammar text))
         (caps (valsi-registry-capabilities grammar tree))
         (version (1+ (if existing (valsi-proto-doc-version existing) 0)))
         (doc (valsi-proto-doc-create :uri uri :text text :version version
                                     :grammar grammar :tree tree :caps caps)))
    (puthash uri doc valsi-proto--docs)
    (list :uri uri :grammar grammar :capabilities caps :version version)))

(defun valsi-proto--register (spec)
  "Register JSON-safe grammar declaration SPEC and hot-reload open documents."
  (let ((id (valsi-registry-register-declaration spec)))
    (maphash
     (lambda (uri doc) (valsi-proto--sync uri (valsi-proto-doc-text doc)))
     valsi-proto--docs)
    id))

(defun valsi-proto--plan-context (uri task-id)
  "Return the plan context for TASK-ID in open document URI, or nil.
This query is intentionally read-only.  Context construction remains owned by
the plan grammar; the wire method merely locates the requested parsed task."
  (let ((doc (gethash uri valsi-proto--docs)))
    (when (and doc task-id (eq (valsi-proto-doc-grammar doc) 'plan))
      (require 'valsi-plan-agent)
      (let* ((root (valsi-proto-doc-tree doc))
             (task
              (cl-find-if
               (lambda (node)
                 (equal task-id (valsi-node-prop node :id)))
               (valsi-node-of-type root 'task))))
        (and task (valsi-plan-context-bundle root task))))))

;;;; Introspection helpers (for the client + tests)

(defun valsi-proto-open-uris ()
  "Return the list of currently open document uris."
  (let (uris) (maphash (lambda (k _v) (push k uris)) valsi-proto--docs) uris))

(defun valsi-proto-reset ()
  "Forget every open document (does not touch the grammar registry)."
  (clrhash valsi-proto--docs))

(provide 'valsi-proto)
;;; valsi-proto.el ends here

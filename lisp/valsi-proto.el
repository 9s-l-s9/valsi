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
;; at the wire.  Nothing above this layer touches a grammar's internals.
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

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-registry)

(cl-defstruct (valsi-proto-doc (:constructor valsi-proto-doc-create))
  "A server-held document.  TREE is in 0-based content offsets."
  uri text (version 0) grammar tree caps)

(defvar valsi-proto--docs (make-hash-table :test 'equal)
  "Map of document uri -> `valsi-proto-doc'.")

(defconst valsi-proto-methods
  '(initialize grammar/register grammar/describe grammar/list grammar/detect
    artifact/didOpen artifact/didChange artifact/didClose
    artifact/symbols artifact/capabilities)
  "The methods this server advertises.")

;;;; Dispatch

(defun valsi-proto-request (method params)
  "Handle an AAP request: METHOD (symbol) with PARAMS (plist) -> response plist.
This is the transport-neutral seam; a stdio transport wraps this call."
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
    (_ (list :error (format "unknown method: %s" method)))))

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
  "Register grammar SPEC and re-resolve every open document (hot-reload)."
  (let ((id (valsi-registry-register spec)))
    (maphash
     (lambda (uri doc) (valsi-proto--sync uri (valsi-proto-doc-text doc)))
     valsi-proto--docs)
    id))

;;;; Introspection helpers (for the client + tests)

(defun valsi-proto-open-uris ()
  "Return the list of currently open document uris."
  (let (uris) (maphash (lambda (k _v) (push k uris)) valsi-proto--docs) uris))

(defun valsi-proto-reset ()
  "Forget every open document (does not touch the grammar registry)."
  (clrhash valsi-proto--docs))

(provide 'valsi-proto)
;;; valsi-proto.el ends here

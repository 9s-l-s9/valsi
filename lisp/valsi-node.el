;;; valsi-node.el --- Typed node model for Valsi artifacts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The transport-neutral node model that is the AAP contract (server side).
;;
;; A parse of any artifact is a tree of `valsi-node' structs overlaid on the
;; buffer.  Every node keeps its buffer region (BEG/END), so views and edits
;; round-trip losslessly.  Unrecognized text is kept as a `prose' node -- a
;; parse never rejects or rewrites (the descriptive-grammar invariant).
;;
;; The struct is deliberately shaped to serialize cleanly to JSON (see
;; `valsi-node-to-plist'): keep it elisp-free in shape so a wire protocol can
;; carry it unchanged.

;;; Code:

(require 'cl-lib)

(cl-defstruct (valsi-node (:constructor valsi-node-create)
                         (:copier valsi-node-copy))
  "A typed node overlaid on an artifact buffer.
TYPE is a symbol (e.g. `task', `group', `prose').  BEG/END are buffer
positions.  CONFIDENCE is `exact' or `loose'.  RECOGNIZER is the symbol of
the recognizer that produced the node (provenance).  PROPS is a plist of
typed fields.  CHILDREN is a list of `valsi-node'."
  (type 'prose)
  (beg nil)
  (end nil)
  (confidence 'exact)
  (recognizer nil)
  (props nil)
  (children nil))

;;;; Property access

(defun valsi-node-prop (node key &optional default)
  "Return property KEY from NODE's plist, or DEFAULT."
  (let ((val (plist-member (valsi-node-props node) key)))
    (if val (cadr val) default)))

(defun valsi-node-put (node key value)
  "Set property KEY to VALUE on NODE and return NODE."
  (setf (valsi-node-props node)
        (plist-put (valsi-node-props node) key value))
  node)

(defun valsi-node-add-child (node child)
  "Append CHILD to NODE's children and return NODE."
  (setf (valsi-node-children node)
        (nconc (valsi-node-children node) (list child)))
  node)

;;;; Region helpers

(defun valsi-node-text (node &optional buffer)
  "Return the buffer text spanned by NODE (from BUFFER or current)."
  (with-current-buffer (or buffer (current-buffer))
    (buffer-substring-no-properties
     (max (point-min) (valsi-node-beg node))
     (min (point-max) (valsi-node-end node)))))

(defun valsi-node-contains-p (node pos)
  "Return non-nil if POS falls within NODE's region."
  (and (valsi-node-beg node) (valsi-node-end node)
       (<= (valsi-node-beg node) pos)
       (< pos (valsi-node-end node))))

;;;; Walking / querying

(defun valsi-node-walk (node fn &optional depth)
  "Call FN with each node in NODE's subtree, depth-first (pre-order).
FN receives (NODE DEPTH)."
  (let ((depth (or depth 0)))
    (funcall fn node depth)
    (dolist (child (valsi-node-children node))
      (valsi-node-walk child fn (1+ depth)))))

(defun valsi-node-collect (node pred)
  "Return a flat list of nodes in NODE's subtree satisfying PRED."
  (let (acc)
    (valsi-node-walk node (lambda (n _d) (when (funcall pred n) (push n acc))))
    (nreverse acc)))

(defun valsi-node-of-type (node type)
  "Return all nodes of TYPE (symbol or list of symbols) in NODE's subtree."
  (let ((types (if (listp type) type (list type))))
    (valsi-node-collect node (lambda (n) (memq (valsi-node-type n) types)))))

(defun valsi-node-at (root pos)
  "Return the innermost node in ROOT covering POS, or nil."
  (let ((found nil))
    (valsi-node-walk
     root
     (lambda (n _d)
       (when (and (valsi-node-contains-p n pos)
                  (or (null found)
                      (>= (valsi-node-beg n) (valsi-node-beg found))))
         (setq found n))))
    found))

(defun valsi-node-at-line (root pos types)
  "Return the node of one of TYPES whose region covers POS in ROOT.
Prefers the node whose BEG is nearest at-or-before POS."
  (let ((types (if (listp types) types (list types)))
        (best nil))
    (valsi-node-walk
     root
     (lambda (n _d)
       (when (and (memq (valsi-node-type n) types)
                  (valsi-node-contains-p n pos)
                  (or (null best)
                      (>= (valsi-node-beg n) (valsi-node-beg best))))
         (setq best n))))
    best))

;;;; Transforms (offset<->buffer translation, copying, rehydration)

(defun valsi-node-shift (node delta)
  "Add DELTA to BEG/END throughout NODE's subtree and return NODE.
Used at the client boundary to translate document offsets to buffer positions."
  (when node
    (valsi-node-walk
     node
     (lambda (n _d)
       (when (valsi-node-beg n)
         (setf (valsi-node-beg n) (+ (valsi-node-beg n) delta)))
       (when (valsi-node-end n)
         (setf (valsi-node-end n) (+ (valsi-node-end n) delta))))))
  node)

(defun valsi-node-deep-copy (node)
  "Return a deep copy of NODE: fresh structs and child lists.
PROPS plists are shared (values are treated as immutable and never mutated);
only BEG/END are mutated by callers, and those are per-struct slots."
  (when node
    (let ((copy (valsi-node-copy node)))
      (setf (valsi-node-children copy)
            (mapcar #'valsi-node-deep-copy (valsi-node-children node)))
      copy)))

(defun valsi-node-from-plist (pl)
  "Rehydrate a node tree from a serialized plist PL (see `valsi-node-to-plist').
Best-effort inverse for a text transport; scalar prop value types are not
restored (a stdio transport needs a type-preserving codec -- see valsi-proto)."
  (valsi-node-create
   :type (intern (plist-get pl :type))
   :beg (plist-get pl :beg)
   :end (plist-get pl :end)
   :confidence (intern (or (plist-get pl :confidence) "exact"))
   :recognizer (let ((r (plist-get pl :recognizer))) (and r (intern r)))
   :props (plist-get pl :props)
   :children (mapcar #'valsi-node-from-plist
                     (append (plist-get pl :children) nil))))

;;;; JSON serialization (the wire shape)

(defun valsi-node-to-plist (node)
  "Return NODE as a JSON-ready plist tree (positions as integers)."
  (list :type (symbol-name (valsi-node-type node))
        :beg (valsi-node-beg node)
        :end (valsi-node-end node)
        :confidence (symbol-name (valsi-node-confidence node))
        :recognizer (and (valsi-node-recognizer node)
                         (symbol-name (valsi-node-recognizer node)))
        :props (valsi-node--props-to-json (valsi-node-props node))
        :children (vconcat (mapcar #'valsi-node-to-plist
                                   (valsi-node-children node)))))

(defun valsi-node--props-to-json (props)
  "Coerce PROPS plist into a JSON-friendly plist (deep-sanitized values)."
  (let (out)
    (while props
      (setq out (plist-put out (car props)
                           (valsi-node--json-sanitize (cadr props))))
      (setq props (cddr props)))
    out))

(defun valsi-node--json-sanitize (v)
  "Recursively coerce V into a JSON-friendly value.
Symbols become strings, dotted pairs and lists become vectors."
  (cond
   ((null v) :json-null)
   ((symbolp v) (symbol-name v))
   ((numberp v) v)
   ((stringp v) v)
   ((vectorp v) (vconcat (mapcar #'valsi-node--json-sanitize v)))
   ((consp v)
    (if (and (cdr v) (not (consp (cdr v))))
        ;; dotted pair (a . b) -> [a b]
        (vector (valsi-node--json-sanitize (car v))
                (valsi-node--json-sanitize (cdr v)))
      (vconcat (mapcar #'valsi-node--json-sanitize v))))
   (t (format "%s" v))))

(provide 'valsi-node)
;;; valsi-node.el ends here

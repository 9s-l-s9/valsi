;;; aap-conformance.el --- AAP v0 conformance suite -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The machine-checkable conformance suite for the Agent Artifact Protocol
;; (AAP) v0.  It asserts the contract documented in doc/aap-spec.md against a
;; server, exercising only the transport-neutral request boundary
;; (`valsi-proto-request': METHOD symbol + PARAMS plist -> response plist).
;;
;; ANY implementation is conformant if it exposes an equivalent request entry
;; point and passes these tests.  The reference server is the elisp
;; `valsi-proto'; a non-Emacs server reuses this suite by binding
;; `valsi-aap-request-function' to its own JSON-RPC client and providing the
;; same node-model JSON shape (see doc/aap-spec.md section "Node model").
;;
;; Run standalone:  make conformance
;; Run in-suite:    make check   (valsi-test.el requires this file)

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'valsi)          ; registers the bundled grammars via `valsi-init'
(require 'valsi-proto)
(require 'valsi-node)

(defvar valsi-aap-request-function #'valsi-proto-request
  "The AAP request boundary under test: (METHOD PARAMS) -> response plist.
Rebind to a foreign server's client to run this suite against it.")

(defun valsi-aap--req (method &rest params)
  "Send METHOD with PARAMS (a flat plist) through the request boundary."
  (funcall valsi-aap-request-function method params))

(defconst valsi-aap--required-methods
  '("initialize"
    "grammar/register" "grammar/describe" "grammar/list" "grammar/detect"
    "artifact/didOpen" "artifact/didChange" "artifact/didClose"
    "artifact/symbols" "artifact/capabilities")
  "The methods an AAP v0 server MUST advertise from `initialize'.")

(defconst valsi-aap--sample-plan
  "# Tasks\n\n## Phase 1: Setup\n\n- [ ] T001 do a thing\n- [x] T002 done thing (depends on T001)\n"
  "A minimal plan artifact used across conformance tests.")

(defun valsi-aap--setup ()
  "Register the bundled grammars and clear the document store."
  (valsi-init)
  (when (fboundp 'valsi-proto-reset) (valsi-proto-reset)))

;;;; initialize / capabilities advertisement

(ert-deftest valsi-aap-conformance-initialize-advertises-methods ()
  "initialize advertises at least the required v0 method set."
  (valsi-aap--setup)
  (let ((caps (plist-get (valsi-aap--req 'initialize) :capabilities)))
    (should (listp caps))
    (dolist (m valsi-aap--required-methods)
      (should (member m caps)))))

(ert-deftest valsi-aap-conformance-unknown-method-errors ()
  "An unknown method returns a response carrying :error, never signals."
  (valsi-aap--setup)
  (let ((resp (valsi-aap--req 'no/such-method)))
    (should (plist-get resp :error))))

;;;; grammar/*

(ert-deftest valsi-aap-conformance-grammar-list ()
  "grammar/list includes the always-present generic fallback grammar."
  (valsi-aap--setup)
  (let ((grammars (plist-get (valsi-aap--req 'grammar/list) :grammars)))
    (should (memq 'generic grammars))))

(ert-deftest valsi-aap-conformance-grammar-detect ()
  "grammar/detect resolves a plan artifact to a non-generic grammar id."
  (valsi-aap--setup)
  (let ((id (plist-get (valsi-aap--req 'grammar/detect
                                      :uri "specs/001/tasks.md"
                                      :text valsi-aap--sample-plan)
                       :id)))
    (should (symbolp id))
    (should (eq id 'plan))))

(ert-deftest valsi-aap-conformance-grammar-describe ()
  "grammar/describe returns id + name + evidence tier for a known grammar."
  (valsi-aap--setup)
  (let ((d (valsi-aap--req 'grammar/describe :id 'plan)))
    (should (eq 'plan (plist-get d :id)))
    (should (stringp (plist-get d :name)))
    (should (memq (plist-get d :evidence)
                  '(standardized converging emergent)))))

;;;; artifact lifecycle + versioning

(ert-deftest valsi-aap-conformance-didopen-shape ()
  "artifact/didOpen returns uri, grammar, capabilities, and version = 1."
  (valsi-aap--setup)
  (let ((r (valsi-aap--req 'artifact/didOpen
                          :uri "tasks.md" :text valsi-aap--sample-plan)))
    (should (equal "tasks.md" (plist-get r :uri)))
    (should (symbolp (plist-get r :grammar)))
    (should (listp (plist-get r :capabilities)))
    (should (= 1 (plist-get r :version)))))

(ert-deftest valsi-aap-conformance-didchange-increments-version ()
  "artifact/didChange bumps the document version monotonically."
  (valsi-aap--setup)
  (valsi-aap--req 'artifact/didOpen :uri "tasks.md" :text valsi-aap--sample-plan)
  (let ((r (valsi-aap--req 'artifact/didChange
                          :uri "tasks.md"
                          :text (concat valsi-aap--sample-plan
                                        "- [ ] T003 more\n"))))
    (should (equal "tasks.md" (plist-get r :uri)))
    (should (= 2 (plist-get r :version)))))

(ert-deftest valsi-aap-conformance-capabilities-match-didopen ()
  "artifact/capabilities agrees with the caps reported at didOpen."
  (valsi-aap--setup)
  (let* ((o (valsi-aap--req 'artifact/didOpen
                           :uri "tasks.md" :text valsi-aap--sample-plan))
         (c (valsi-aap--req 'artifact/capabilities :uri "tasks.md")))
    (should (equal (plist-get o :capabilities)
                   (plist-get c :capabilities)))))

(ert-deftest valsi-aap-conformance-didclose-forgets ()
  "artifact/didClose removes the document; symbols then returns nil."
  (valsi-aap--setup)
  (valsi-aap--req 'artifact/didOpen :uri "tasks.md" :text valsi-aap--sample-plan)
  (valsi-aap--req 'artifact/didClose :uri "tasks.md")
  (should (null (valsi-aap--req 'artifact/symbols :uri "tasks.md"))))

;;;; Node model (the served semantic tree)

(ert-deftest valsi-aap-conformance-symbols-node-model ()
  "artifact/symbols returns a node tree honoring the v0 node-model contract:
a typed root at 0-based offsets; every node bounded within the document, ordered
(beg <= end), and each child beginning at or after its parent (document order)."
  (valsi-aap--setup)
  (valsi-aap--req 'artifact/didOpen :uri "tasks.md" :text valsi-aap--sample-plan)
  (let ((root (valsi-aap--req 'artifact/symbols :uri "tasks.md"))
        (len (length valsi-aap--sample-plan)))
    (should (valsi-node-p root))
    ;; root spans the whole document at 0-based offsets
    (should (= 0 (valsi-node-beg root)))
    (should (<= (valsi-node-end root) len))
    (valsi-aap--assert-node-invariants root len)))

(defun valsi-aap--assert-node-invariants (node len)
  "Assert NODE and its subtree satisfy the v0 node-model contract for a LEN doc.
Typed; `exact|loose' confidence; 0-based bounded, ordered offsets; children in
document order (each child begins at or after its parent).  The model is a
logical outline tree -- a heading/group node's own region is its header line, so
children follow it rather than being byte-contained within it."
  (should (symbolp (valsi-node-type node)))
  (should (memq (valsi-node-confidence node) '(exact loose)))
  (should (integerp (valsi-node-beg node)))
  (should (integerp (valsi-node-end node)))
  (should (<= 0 (valsi-node-beg node)))
  (should (<= (valsi-node-beg node) (valsi-node-end node)))
  (should (<= (valsi-node-end node) len))
  (dolist (child (valsi-node-children node))
    (should (<= (valsi-node-beg node) (valsi-node-beg child)))
    (valsi-aap--assert-node-invariants child len)))

(ert-deftest valsi-aap-conformance-node-serialization-roundtrip ()
  "The node model survives to-plist -> from-plist unchanged (the wire shape)."
  (valsi-aap--setup)
  (valsi-aap--req 'artifact/didOpen :uri "tasks.md" :text valsi-aap--sample-plan)
  (let* ((root (valsi-aap--req 'artifact/symbols :uri "tasks.md"))
         (pl (valsi-node-to-plist root))
         (back (valsi-node-from-plist pl)))
    ;; plist form is JSON-ready: type is a string, children a vector
    (should (stringp (plist-get pl :type)))
    (should (vectorp (plist-get pl :children)))
    ;; round-trip preserves shape
    (should (eq (valsi-node-type root) (valsi-node-type back)))
    (should (= (valsi-node-beg root) (valsi-node-beg back)))
    (should (= (valsi-node-end root) (valsi-node-end back)))
    (should (= (length (valsi-node-children root))
               (length (valsi-node-children back))))))

;;;; grammar/register hot-reload

(ert-deftest valsi-aap-conformance-register-hot-reloads ()
  "grammar/register re-resolves already-open documents with no reopen.
This is AAP's liveness guarantee: a grammar registered into the running server
updates the capabilities of documents opened before it existed."
  (valsi-aap--setup)
  (let ((uri "custom.demo"))
    ;; Open a document no bundled grammar specifically claims.
    (valsi-aap--req 'artifact/didOpen :uri uri :text "# demo\n\nhello\n")
    (should-not
     (memq 'demo-cap
           (plist-get (valsi-aap--req 'artifact/capabilities :uri uri)
                      :capabilities)))
    ;; Register a grammar that claims .demo; the OPEN doc must re-resolve.
    (valsi-aap--req 'grammar/register
                   :spec (list :id "demo"
                               :name "Demo"
                               :evidence "emergent"
                               :rootType "root"
                               :match (list :uriSuffix ".demo" :score 10)
                               :recognizers
                               (vector (list :type "heading"
                                             :regexp "^# +\\(.*\\)$"
                                             :properties (list :title 1)))
                               :capabilities ["demo-cap"]))
    ;; No re-open: the server re-synced the open doc under the new grammar.
    (should
     (memq 'demo-cap
           (plist-get (valsi-aap--req 'artifact/capabilities :uri uri)
                      :capabilities)))))

(provide 'aap-conformance)
;;; aap-conformance.el ends here

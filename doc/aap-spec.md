# Agent Artifact Protocol (AAP) — specification v0

Status: **v0 (extracted, not yet a standard).** Version 0 is *derived* from Valsi's
working server (`lisp/valsi-proto.el`) once two independent grammar genres
(plan/tasks + instruction) run as plugins and prove the model's adaptability —
per [ADR 0004](adr/0004-artifact-protocol.md) and Valsi's "derive, don't invent"
method. It is **not called a standard** until a second independent implementation
exists (targeted v1.x, Sprint 12). Breaking changes are allowed within v0.

A conformance suite ships with this spec: `test/conformance/aap-conformance.el`
(run `make conformance`). Any implementation that passes it is AAP-v0-conformant.

## 1. Scope and non-goals

AAP is an **LSP-style wire protocol for agent artifacts** — the plain-markdown
files agents and humans co-author (plans, instruction files, prompt files,
memory, changelogs, ADRs, …). It standardizes three things and nothing more:

1. the **request envelope** (methods + params/response shapes),
2. the **node model** (the typed, region-preserving semantic tree a server
   returns for a document), and
3. **grammar declaration + registration** (how a server is taught new artifact
   types at runtime).

**Non-goals** (deliberately out of scope, per ADR 0004):

- The specific grammars. Like LSP does not standardize how C++ is parsed, AAP
  does not standardize how a plan is parsed — only the requests and the model.
- Agent dispatch / tool use. That rides MCP and the provider transport,
  client-side. AAP is artifacts-only.
- The editing UI, keymaps, and views. Those are client concerns.

## 2. Model overview

- **Descriptive, never normative.** A grammar annotates plain markdown; it never
  rejects or rewrites it. Every document is valid. Parsing is a pure function of
  the document *text* (no live buffer, no cursor).
- **Client/server split (eglot model).** The **server** owns parse, the node
  model, grammar plugins, diagnostics, and capability advertisement. The
  **client** owns the buffer (always-editable markdown), views, and keymaps.
- **Degradation ladder = per-document capability advertisement.** The server
  reports which requests a document supports *given the structure its grammar
  actually resolved*. A file with less structure simply advertises fewer
  capabilities; it is never an error.

## 3. Transport

A request is `METHOD` (a name) + `PARAMS` (an object) → a response object. The
reference server realizes this in-process as
`valsi-proto-request(method, params) → response` (elisp values; "same JSON types,
no stdio"). A networked server wraps exactly this boundary in JSON-RPC 2.0 over
stdio (`jsonrpc.el`), serializing params/response with the node-model JSON shape
of §5 at the wire. Nothing above the boundary changes.

Method names group by prefix: `initialize`, `grammar/*`, `artifact/*`.

## 4. Methods (v0)

A conformant server MUST advertise all of the following from `initialize`.

### `initialize`
- **params**: none required.
- **result**: `{ capabilities: string[] }` — the method names this server
  supports (a superset of the required set below is allowed).

Required method set:
`initialize`, `grammar/register`, `grammar/describe`, `grammar/list`,
`grammar/detect`, `artifact/didOpen`, `artifact/didChange`,
`artifact/didClose`, `artifact/symbols`, `artifact/capabilities`.

### `grammar/register`
- **params**: `{ spec: GrammarSpec }` (see §6).
- **result**: `{ id: GrammarId }`.
- **effect (hot-reload)**: the server MUST re-resolve every currently-open
  document against the updated registry, with no reopen. A grammar registered
  now updates the capabilities of documents opened before it existed. *(This is
  the liveness guarantee; the conformance suite tests it directly.)*

### `grammar/describe`
- **params**: `{ id: GrammarId }`.
- **result**: `{ id, name: string, evidence: "standardized"|"converging"|"emergent", … }`.

### `grammar/list`
- **result**: `{ grammars: GrammarId[] }` — MUST include the always-present
  `generic` fallback.

### `grammar/detect`
- **params**: `{ uri: string, text: string }`.
- **result**: `{ id: GrammarId }` — the highest-scoring grammar for the document
  (falls back to `generic`). Detection is a pure function of `(uri, text)`.

### `artifact/didOpen` and `artifact/didChange`
- **params**: `{ uri: string, text: string }`.
- **result**: `{ uri, grammar: GrammarId, capabilities: Capability[], version: int }`.
- **semantics**: the server detects the grammar, parses `text` into the node
  model, caches it, and advertises capabilities. `version` starts at 1 on the
  first open and increments monotonically on every open/change of that `uri`.

### `artifact/didClose`
- **params**: `{ uri: string }`.
- **result**: `{ uri }`. The server forgets the document; a later
  `artifact/symbols` for it MUST return null.

### `artifact/symbols`
- **params**: `{ uri: string }`.
- **result**: the document's root `Node` (§5) in 0-based offset coordinates, or
  null if the document is not open.

### `artifact/capabilities`
- **params**: `{ uri: string }`.
- **result**: `{ capabilities: Capability[] }` — MUST equal the capabilities
  reported by the most recent `didOpen`/`didChange` for that `uri`.

### Unknown methods
A server MUST respond with an object carrying an `error` field (it MUST NOT crash
the transport).

## 5. Node model

The semantic tree a server returns. Coordinates are **0-based offsets into the
document text** (a pure function of text — no buffer, no point). JSON shape (as
emitted by `valsi-node-to-plist`):

```json
{
  "type":       "task",            // string: the node kind (grammar-defined)
  "beg":        42,                // int: inclusive start offset
  "end":        87,                // int: exclusive end offset
  "confidence": "exact",           // "exact" | "loose"  (provenance)
  "recognizer": "valsi-plan-task",  // string|null: which recognizer produced it
  "props":      { "id": "T001" },  // object: typed, grammar-defined fields
  "children":   [ /* Node[] */ ]   // array of child nodes
}
```

Invariants a conformant tree MUST satisfy (checked by the suite):

1. **Typed.** Every node has a `type`.
2. **Confidence.** `confidence ∈ {exact, loose}` — descriptive provenance;
   `loose` marks a tolerant/heuristic recognition, never an error.
3. **Bounded, ordered offsets.** `0 ≤ beg ≤ end ≤ len(text)` for every node.
4. **Document order.** The tree is a *logical outline*, not a byte-containment
   tree: a heading/group node's own region is typically just its header line, and
   its children follow it in the document. The guarantee is therefore
   `parent.beg ≤ child.beg` (each child begins at or after its parent), and
   siblings appear in document order — **not** `child.end ≤ parent.end`.
5. **Round-trippable.** to-JSON → from-JSON preserves type/offsets/children —
   the wire form and the in-memory form agree. (`props` values are JSON scalars,
   arrays, or objects.)

`props` is an open, grammar-defined map (e.g. a plan `task` carries
`{id, state, deps, pathrefs, traces}`; an instruction `frontmatter` carries
`{description, globs, applyTo, alwaysApply}`). AAP does not standardize the keys —
only that `props` is a JSON object.

## 6. Grammar declaration

A `GrammarSpec` is the registerable unit (`grammar/register`). Fields:

| Field | Type | Meaning |
|---|---|---|
| `id` | symbol/string, unique | the grammar's identity |
| `name` | string | human label |
| `evidence` | `standardized`\|`converging`\|`emergent` | how real the format's structure is |
| `match` | `(uri, text) → score` | detection; higher wins; pure |
| `parse` | `(text) → Node` | the pure parser → node model |
| `capabilities` | `(Node) → Capability[]` | per-document degradation-ladder advertisement |
| `font-lock`, `commands` | client-side hints | opaque to the protocol |

`evidence` records the honesty of the mapping (a *standard* like Keep a Changelog
vs. an *emergent convention* like AGENTS.md) so clients can calibrate trust. The
`generic` grammar is always registered as the universal fallback.

## 7. Capabilities (the ladder)

`capabilities` is a set of opaque capability tokens the server advertises per
document. They express the degradation ladder: more resolved structure → more
capabilities. AAP does not fix the token vocabulary in v0 (it is grammar-defined,
e.g. `outline`, `narrow`, `dashboard`, `effective`, `lint`, `dispatch`); it fixes
only that the set is advertised, is a pure function of the resolved tree, and is
queryable via `artifact/capabilities`. v1 is expected to standardize a core token
vocabulary once more grammars settle it.

## 8. Edit envelope (informative, v0)

Agent-proposed edits are surfaced to the user as a **reviewable node-diff** keyed
by stable node identity (e.g. a plan task's `id`), never a silent text overwrite —
the "control over delegation" invariant. The reference client computes this
client-side (`valsi-plan-diff` / `valsi-plan-apply-changes`): added / removed /
modified nodes, each independently acceptable, with the guarantee that rejecting
all changes restores the document byte-identically. v0 documents this shape as
**informative**; promoting an `artifact/applyEdit` request into the normative
method set is deferred to v1 once a second grammar exercises it.

## 9. Conformance

`test/conformance/aap-conformance.el` (`make conformance`) asserts §4–§6 against
a server through the request boundary of §3. To certify a **foreign**
implementation, rebind `valsi-aap-request-function` to a client of that server and
run the suite; passing it is the v0 conformance bar. The suite covers: method
advertisement, unknown-method handling, grammar list/detect/describe, the
artifact lifecycle + monotonic versioning, capability agreement, the node-model
invariants (§5.1–§5.5), and grammar-registration hot-reload (§4).

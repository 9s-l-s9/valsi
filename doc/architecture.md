# Valsi architecture

Seed document (fleshed out in Sprint 2, T208). For the *why*, see the ADRs in
`doc/adr/`. For the roadmap, see `PLAN.md`.

## Client/server & the Agent Artifact Protocol (AAP)

Valsi is the reference implementation of **AAP**, an LSP-style JSON-RPC protocol
for agent artifacts (ADR 0004). The system is a **client/server split** on the
eglot model:

```
  Emacs client (valsi.el, valsi-view, transients, agent brain)
        │  JSON-RPC over stdio (jsonrpc.el)
        ▼
  valsi-server  (headless Emacs)
    ├─ valsi-proto     JSON-RPC transport + AAP request/edit types
    ├─ valsi-node      typed node model + regions  ← the transport-neutral contract
    ├─ valsi-parse     recognizer registry + incremental reparse
    ├─ valsi-registry  grammar-plugin loader; grammar/register + hot-reload
    ├─ grammar plugins (valsi-plan, valsi-instruction, valsi-promptfile, …)
    └─ valsi-graph     cross-artifact link graph
```

- **Server** = the editor-agnostic *model*: parse, node tree, grammar plugins,
  diagnostics, edits, graph. Runs as a headless Emacs so grammars stay elisp;
  other editors may implement their own server.
- **Client** = Emacs, where the differentiated value lives: turning the server's
  node model into bespoke **views** (font-lock, tabulated-list agendas/coverage,
  node-diff review UI) and **keymaps/transients** from raw buffers — the thing
  Emacs is uniquely good at. The buffer stays plain, editable markdown at all
  times (liveness invariant, client-side).
- **Agent brain** (`valsi-agent*`) is client-side and rides **MCP** / the provider
  transport — *not* part of AAP. AAP is artifacts-only.

### The node model (the contract)

A typed node overlaid on the buffer: `type`, buffer `region`, `confidence`
(`exact | loose`), the producing recognizer (provenance), props, children. Every
node round-trips losslessly (`parse → serialize` is the identity). This structure
is JSON-serializable and is the center of every AAP message.

### AAP method groups

1. **Lifecycle / sync** — `initialize` (capability negotiation), `artifact/didOpen`,
   `artifact/didChange` (incremental), `didClose`.
2. **Queries** — `artifact/symbols`, `nav/definition`, `nav/references`, `hover`,
   `graph/resolve`.
3. **Diagnostics** — server→client push `artifact/publishDiagnostics` (severities
   + code-action fixes).
4. **Edits** — node-diff / WorkspaceEdit-analog with per-node accept/reject review;
   structure ops return edits, never mutate blindly.
5. **Grammar capability (adaptable core)** — `grammar/register`, `grammar/reload`
   (hot, no restart), `grammar/describe`. The **degradation ladder is expressed as
   per-document capability advertisement**: the server reports which requests a
   document supports given the structure its grammar actually resolved — a grammar
   advertising what it can answer, not server incompleteness.

The spec is *extracted* from this running server at Sprint 8 (`doc/aap-spec.md`),
once two grammar genres prove adaptability — not designed up front.

## Grammars are plugins

Every artifact family (plan/tasks, instruction, prompt-file, memory, and the
v1.x decision/journal/changelog/handoff families) is an AAP grammar plugin: a set
of recognizers → node types → the requests/commands it advertises. Adding a new
artifact type is writing and registering a grammar — the third-party on-ramp
(grammar SDK, Sprint 12). See `doc/defining-a-grammar.md` (Sprint 2).

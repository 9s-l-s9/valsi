# Valsi architecture

For the *why*, see the ADRs in
`doc/adr/`.

## Artifact application and agent boundary

ADR 0006 makes Valsi a Magit-like application for agent artifacts rather than a
second agent frontend. A native project hub, grammar-specific dashboards,
inspectors, verification, graph, and node-review buffers are the application.
Ordinary Markdown files remain authoritative.

Agent interaction runs in real terminal-emulator buffers. Eat is the initial
implementation; Pi is the default Guix-pinned CLI, while Codex CLI, Claude Code,
and custom programs may occupy the same role with declared capabilities. The
CLI owns its prompt, transcript, provider authentication, models, tools,
confirmations, context accounting, and sessions. Valsi owns project association,
process/focus conveniences, and explicit artifact handoff. It never scrapes
terminal cells to reproduce structured state.

The later named-instance, collision-warning, and Git-worktree model is
specified in `doc/multi-agent.md`.  It extends this boundary without adding an
agent messaging or transcript layer.

The earlier `valsi-harness`/`valsi-pi` RPC implementation and native Elisp
agent loop remain historical/test source outside the product load graph. The
only retained Pi integration is the narrow, read-only AAP artifact extension.

Normal agent processes receive their normal project capabilities; task
manifests and selected artifacts provide semantic context rather than per-file
authorization. Backend sandbox/approval behavior is authoritative. Agent
execution remains outside AAP.

## Client/server & the Agent Artifact Protocol (AAP)

Valsi is the reference implementation of **AAP**, an LSP-style protocol for
agent artifacts (ADR 0004). The current v1.0 client/server boundary runs
in-process; a JSON-safe adapter is ready for a future JSON-RPC stdio envelope:

```
  Emacs client (valsi.el, valsi-view, transients, agent brain)
        │  native request boundary (v1.0)
        │  JSON-safe adapter available for future stdio
        ▼
  AAP server model (currently in the Emacs process)
    ├─ valsi-proto     native request handler + JSON wire adapter
    ├─ valsi-node      typed node model + regions  ← the transport-neutral contract
    ├─ valsi-parse     recognizer helpers + full content parse
    ├─ valsi-registry  grammar-plugin loader; grammar/register + hot-reload
    ├─ grammar plugins (valsi-plan, valsi-instruction, valsi-promptfile, …)
    └─ valsi-graph     cross-artifact link graph
```

- **Server model** = the editor-agnostic parse, node tree, grammar-plugin,
  capability, and graph layers. It currently runs inside Emacs. Moving it to a
  headless process requires only the JSON-RPC envelope and process lifecycle;
  `valsi-proto-json-request` already enforces JSON-safe method values.
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
   `artifact/didChange` (full-text v0 sync), `didClose`.
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

The spec is *extracted* from this running server (`doc/aap-spec.md`),
once two grammar genres prove adaptability — not designed up front.

## Grammars are plugins

Every artifact family (plan/tasks, instruction, prompt-file, memory, and the
v1.x decision/journal/changelog/handoff families) is an AAP grammar plugin: a set
of recognizers → node types → the requests/commands it advertises. Adding a new
artifact type is writing and registering a grammar — the third-party on-ramp
(a future grammar SDK).

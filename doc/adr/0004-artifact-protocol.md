# 4. Valsi is the reference implementation of an Agent Artifact Protocol

Date: 2026-07-13

## Status

Accepted. Shapes the substrate and everything downstream. Supersedes the
implicit "Valsi is an in-process Emacs minor-mode" assumption in ADR 0001's
framing (0001's *descriptive-grammar* decision still holds).

**Realized.** Decision 7 ("extract the spec, don't invent it") is now
executed: with two independent grammar genres running as plugins (plan/tasks +
instruction), the protocol was extracted from the working server into
[`doc/aap-spec.md`](../aap-spec.md) as **v0**, shipping with a machine-checkable
conformance suite (`test/conformance/`, `make conformance`). Per this ADR it
remains an *extracted spec*, not a *standard*, until a second independent
implementation passes the suite (targeted v1.x).

## Context

Valsi's core idea is a **descriptive grammar** over agent artifacts (plain
markdown that is annotated, never rejected). Two forces pushed this from "an
Emacs feature" toward "a protocol":

- **Strategy.** A small project cannot win as a monolithic agent harness against
  the large labs. A neutral, *adaptable* standard can be adopted — including by
  competitors — the way LSP and MCP were. The leverage is being the layer others
  build on, not the biggest app.
- **Adaptability is the actual product.** People will want to define *their own*
  artifact types and dialects. The reusable, valuable unit is therefore the
  **grammar-definition mechanism**, not a fixed analyzer (parsing a checkbox is
  trivial; the analyzer is not the moat).

The agent-protocol landscape (2026) already covers the transports around this —
**MCP** (agent↔tools), **A2A** (agent↔agent), **ACP** (agent↔editor), all
converging under the Linux Foundation. None of them models the **semantic content
of the artifacts themselves**. That layer is the gap, and it is exactly Valsi's
substrate.

A wire protocol appears to conflict with Valsi's "live, self-modifying, in-Emacs"
commitments and with the fact that **Emacs was chosen because building bespoke
views + keybindings from raw text buffers is its defining strength** (cheaper than
VS Code). The decision must preserve both.

## Decision

Valsi is the **reference implementation of the Agent Artifact Protocol (AAP)**, an
LSP-style **wire protocol (JSON-RPC)** focused on agent artifacts.

1. **Client/server split (eglot model).** A `valsi-server` owns parse, the typed
   node model, grammar plugins, diagnostics, edit computation, and the
   cross-artifact graph. The **Emacs client** owns the buffer (plain markdown,
   always editable), views, keymaps, and transients. Editing + liveness are
   client-side; the semantic model is served.
2. **Grammars are hot-registrable server plugins.** `grammar/register` /
   `grammar/reload` / `grammar/describe`. "Extensible while running" becomes an
   *addressable protocol capability* (register/reload a grammar into the running
   server, no restart) — which is also what lets third parties add artifact types.
3. **AAP standardizes the envelope, model, and grammar-declaration — never the
   specific grammars.** Like LSP doesn't standardize how C++ is parsed, only the
   requests. The **degradation ladder becomes per-document capability
   advertisement** (the server reports which requests a document supports given
   the structure its grammar resolved).
4. **Agent dispatch is out of scope for AAP.** It stays a client-side concern
   riding MCP / the provider transport. AAP is artifacts-only, kept narrow.
5. **Reference server runtime = a headless Emacs** hosting the elisp grammar
   plugins over stdio via `jsonrpc.el` (the library eglot uses — pure-elisp,
   Guix-friendly). Emacs is thus both reference client and reference server host;
   other editors may implement their own server or reuse the elisp one.
6. **Why Emacs = the client competency.** The server/protocol is the
   editor-agnostic commodity others can reimplement; Valsi's differentiated value
   is the Emacs client (views/keymaps from buffers). Valsi does not chase UI
   editor-neutrality; it bets the best client lives in Emacs while the model stays
   portable.
7. **Extract the spec, don't invent it.** AAP exists from the start as Valsi's
   *internal* contract. It is *formalized/published as v0* only once
   two independent grammar genres (plan/tasks + instruction) run as plugins and
   prove the adaptability — Valsi's own "derive, don't invent" method applied to
   the protocol. A conformance suite ships with it. It is not called a standard
   until a second independent consumer exists (v1.x).

## Consequences

**Positive**

- The reusable/adaptable unit (grammars) is first-class and portable; third
  parties can define their own artifact types against a documented interface.
- Positions Valsi in the empty artifact-model layer, complementary to (not
  competing with) MCP/ACP/A2A.
- The model becomes reusable by non-Emacs clients later, without changing the
  core, via the wire protocol.

**Negative / costs**

- A process boundary is introduced (the accepted cost of the wire choice). It can
  fight iteration speed. *Mitigation*: liveness preserved via hot grammar
  registration; an in-process transport (same JSON types, no stdio) is a drop-in
  fallback if needed.
- More architecture up front: `valsi-proto`, `valsi-registry`, `valsi-server`, and a
  client/server discipline the substrate must carry.
- Standard-building has governance/neutrality obligations — deferred,
  kept light until adoption warrants it.

**Neutral**

- The Emacs client remains where the differentiated value and effort concentrate;
  the protocol raises the ceiling without lowering the near-term feature scope of
  v1.0.

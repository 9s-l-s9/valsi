# 3. Provider-agnostic agent core, subscription-OAuth-first

Date: 2026-07-13

## Status

Accepted; **implemented**. Records the agent-core layering, the
provider abstraction, and — the load-bearing part — the **authentication
strategy**. The design landed as `valsi-agent-{provider,auth,tools,session}.el`
and `valsi-agent.el`: the mock loop, tool contract, scoping, sessions, the
subscription-OAuth resolver/refresh/PKCE flow, and the `anthropic-oauth` +
`anthropic-key` adapters, all green under `make check` (the mock path is
CI-tested; the auth/network paths' pure logic is unit-tested). Implementation-
level OAuth constants and flow live in `research/03a-oauth-flow-notes.md`; this
ADR records the *decisions*, that doc records the *values*. **Remaining before
this is fully verified:** the live M5 auth-acceptance run against the
maintainer's real Claude subscription (inherently interactive, not in CI), and
the optional `gptel` adapter (deferred fast-follow).

## Context

Valsi ships its **own first-party agent core** (`valsi-agent*`) rather than
depending on an existing Emacs LLM client. It is modeled on the vendored study
harnesses — the readable tau (`huggingface/tau`) and the more mature pi
(`earendil-works/pi`) / Hermes (`NousResearch/hermes-agent`) — mapped onto Valsi's
modules in `research/03`.

Two facts shape the decision:

- **The maintainer authenticates with a Claude *subscription* (OAuth), not an API
  token.** A design that assumes `ANTHROPIC_API_KEY` is wrong for the primary
  user. Reusing Claude Code's own OAuth credential is the least-friction path.
- **`gptel`** is the obvious existing Emacs option, but it is an **API-key**
  client — it has **no subscription-OAuth path**. Taking it as the core or a hard
  dependency would bake in the wrong auth model and pull a large dependency into
  the agent brain.

The agent core must also stay **reusable and narrow**: it is client-side, rides
**MCP** / the provider transport, and is explicitly **not** part of AAP (ADR
0004). It must depend on nothing Valsi-specific so it never bleeds into the
protocol surface.

## Decision

1. **Provider abstraction first (`valsi-agent-provider`).** A `cl-defgeneric`
   request/stream interface over provider structs. A deterministic **`mock`
   adapter is built first** so the tool-use loop is testable with no network or
   auth. Real adapters implement the same interface.
2. **Subscription OAuth is the default path (`valsi-agent-auth`).** Order of
   resolution, least-friction first:
   1. **Reuse Claude Code's credential** — `CLAUDE_CODE_OAUTH_TOKEN`, then
      `~/.claude/.credentials.json`, then (macOS only) the `Claude Code-credentials`
      Keychain entry. Prefer *reading* Claude Code's store over persisting our own
      copy, to avoid desync (the pi/Hermes model).
   2. **First-party PKCE login** only if no reusable credential exists — S256,
      loopback callback via `make-network-process`, JSON token exchange via
      `url-retrieve`, persisted to `~/.valsi/auth.json`
      (`{access, refresh, expires, account_id}`).
   3. **Auto-refresh** with a **5-minute skew**; write the possibly-rotated
      refresh token back to wherever it was sourced. Refreshing costs zero LLM
      tokens.
   All OAuth constants are centralized in one `defconst` block (per 03a) because
   they are undocumented and will drift — a constant drift must degrade to
   "re-login", not "broken".
3. **`anthropic-oauth` is the primary provider adapter.** Requests must
   **fingerprint as Claude Code** or Anthropic mis-routes / 500s them:
   `Authorization: Bearer` (not `x-api-key`), `anthropic-beta` including
   `claude-code-20250219,oauth-2025-04-20`, and the required Claude-Code system-
   prompt preamble. (Details in 03a §6; this is `valsi-agent-provider` territory,
   pinned here so auth + provider stay consistent.)
4. **`gptel` is demoted to an optional API-key adapter, behind a soft `require`.**
   Never a dependency, never the primary path. An `http` api-key adapter is the
   plain fallback; `gptel`/openai-compatible are secondary/experimental in v1.
5. **Tools are typed and confirmable (`valsi-agent-tools`).** A tool is a JSON-
   Schema-typed schema + an executor returning `{ok, content, data, error}` (the
   tau model), with a `confirm` gate. Structurally convertible to `gptel-tool` but
   not dependent on it.
6. **Sessions are durable plain files (`valsi-agent-session`).** Append-only JSONL
   under `.valsi/sessions/`, resume + branch (tau's tree model) — files over
   formats; git-ignored by default.
7. **Control over delegation.** Every dispatch is scoped (per-dispatch file/tool
   allow-lists), mutating tools are confirmed, dry-run exists — the invariant, not
   a feature flag.

## Acceptance

With **no `ANTHROPIC_API_KEY` set**, Valsi authenticates via the Claude
subscription (OAuth token reused from Claude Code, or a fresh PKCE login) and
completes a live tool-using task — proving the subscription path, not just an
api-key path. A mock-provider ERT run drives the same loop deterministically.

## Consequences

**Positive**

- Matches how the maintainer actually authenticates; zero-config in the common
  case (Claude Code already logged in).
- The agent core stays provider-neutral and dependency-light; the mock adapter
  makes the loop unit-testable before any network exists.
- Keeping `gptel` optional avoids importing an API-key-only auth model or a heavy
  dependency into the brain.

**Negative / costs / risks**

- **Subscription-OAuth fragility**: the endpoints, constants, and "route as
  Claude Code" behaviour are **undocumented and can change**. *Mitigations*:
  constants in one place; prefer reusing Claude Code's store over re-deriving the
  flow; keep the api-key adapter as a working fallback; track three reference
  implementations (tau/pi/hermes) to follow drift.
- **Billing caveat** (surfaced in docs, not enforced): third-party harness use of
  subscription OAuth may draw from *extra usage*, billed per token, not against
  plan limits.
- Owning an agent core is more surface than reusing gptel — accepted, because the
  auth model and the client-side/MCP scoping are exactly what a reused client
  would get wrong.

**Neutral**

- The provider interface leaves room for api-key, openai-compatible, and gptel
  adapters as secondary paths without disturbing the primary OAuth design.

_Cross-refs: `design/agent-core.md` (formerly `research/03-agent-core-references.md`) (layering, tool contract,
session format), `research/03a-oauth-flow-notes.md` (constants + flow), ADR 0004
(why agent dispatch is out of AAP scope)._

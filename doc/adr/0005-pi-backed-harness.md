# 5. Use Pi as Valsi's agent runtime

Date: 2026-07-29

## Status

Accepted for its runtime-ownership evidence; partially superseded by ADR 0006.
ADR 0006 replaces the native RPC chat/composer, duplicated authentication and
session UI, and per-prompt policy direction with stock agent CLIs in real
terminal buffers. This ADR still governs the decisions not to reimplement/fork
Pi, to leave credentials and sessions with Pi, to package a tested release, and
to keep AAP artifacts-only.

## Context

Valsi has a small provider-neutral agent loop, typed tools, OAuth experiments,
and JSONL sessions. Turning that loop into a dependable subscription-backed
coding harness would also require streaming transports, provider churn,
authentication refresh, retry and compaction policy, model discovery, and
session trees. Pi already implements those concerns and provides a documented
JSONL RPC mode intended for embedding.

A source-level Elisp port would copy a large, fast-moving runtime and make Valsi
responsible for maintaining provider-specific behavior. Running Pi's terminal
UI inside Emacs would reuse the runtime but prevent a native prompt-first
dashboard, structured approvals, and artifact-aware policy.

## Decision

Valsi embeds a pinned Pi release as a subprocess in `--mode rpc`.

- Pi owns providers, model metadata, OAuth credentials and refresh, streaming,
  retries, context accounting and compaction, tools, transcripts, and session
  trees.
- Valsi owns the Emacs UI, AAP artifacts and context construction, dispatch
  scope, approvals, verification, and node-diff review.
- `valsi-harness` is the narrow backend boundary. `valsi-pi` implements it over
  Pi RPC. The existing native loop is adapted behind a `native` backend for
  tests and rollback, not developed toward feature parity.
- Upstream Pi is pinned through Guix. A small Valsi Pi extension may enforce
  artifact policy. A fork is permitted only for a missing RPC seam, should be
  minimal, and should carry an upstreaming/retirement condition.
- Pi's session is authoritative. Valsi does not mirror production transcripts
  into `.valsi/sessions/`.

The primary no-API-key acceptance path is OpenAI Codex authenticated with a
ChatGPT subscription through Pi. Credentials remain exclusively in Pi's
credential store. Pi's Claude Pro/Max login may use Anthropic extra usage and
must not be described as included subscription quota.

## Migration and rollback

The migration proceeds behind `valsi-harness-backend`: introduce and test the
contract, implement Pi RPC, move plan dispatch, add the dashboard/policy
extension, then change the default. Until M8 passes, selecting `native`
restores the old in-process path and its deterministic mock provider. Removing
native production auth or migrating old session files is a separate,
deliberate step after M8.

## Consequences

Valsi can concentrate on its Emacs and artifact strengths and inherit Pi's
subscription/provider work. The cost is a Bun-compiled subprocess, protocol-version
compatibility, a packaging dependency, and process-failure handling. Pinning a
tested Pi version, keeping protocol fixtures, reporting stderr separately, and
retaining a small fallback backend contain those costs.

## SDK host re-evaluation

Pi 0.80.6 also exports `createAgentSession`, `createAgentSessionRuntime`,
`AuthStorage`, `ModelRegistry`, and `SessionManager` for a TypeScript host.
That is the right interface when the embedding application already runs on
Node/Bun and wants to own Pi's process-level control plane. It is not a more
direct in-process interface for Emacs: Valsi would still need a local process
and a serialized protocol.

The pinned SDK and the current integration were compared after native
subscription login succeeded on 2026-07-30:

| Concern | Stock RPC plus extension | Separate SDK host |
|---|---|---|
| Prompt/steer/follow-up/abort | Documented RPC commands | Re-serialize `AgentSession` calls |
| Streaming and state | Documented RPC events/state | Design and maintain an event protocol |
| Session replacement | Stock RPC runtime | Recreate `AgentSessionRuntime`; rebind subscriptions and extensions after replacement |
| Credentials/models | Stock process owns defaults | Construct the same `AuthStorage` and `ModelRegistry` |
| Valsi policy/AAP/auth UI | Public extension APIs | Load the same extension or duplicate its behavior |
| Packaging | One checksummed, byte-preserved release binary | Package the SDK plus its JavaScript dependency closure and host |
| Compatibility | Golden RPC traces fail closed | Host API/types and the new wire protocol both require compatibility gates |

Valsi therefore stays on stock RPC. The extension currently uses only supported
interfaces: extension hooks for policy and AAP, `AuthStorage.login` and
`ModelRegistry.getProviderAuthStatus` for non-secret authentication UI, and
`SessionManager.list` for projected session metadata. There are no Pi core
patches or private-store reads. The host-adapter gate remains: reconsider when
at least two required features need private internals/core patches, or when the
versioned RPC boundary can no longer fail closed. A future adapter must remain
an independently replaceable local process behind `valsi-harness`; it must not
move Pi credentials, transcripts, or model/session machinery into Emacs Lisp.

# The Valsi agent core

> **Removed from the tree (2026-07-30):** ADR 0005 superseded this native
> core with Pi RPC; ADR 0006 subsequently superseded the custom RPC chat
> frontend with stock agent CLIs in terminal-emulator buffers. The
> `valsi-agent*.el` modules described below have now been deleted from the
> working tree to keep it uncluttered; they remain retrievable from git history
> (through the Sprint 11 commit). This document is kept as historical design
> rationale, not current setup guidance.

Valsi previously shipped its own first-party agent brain to explore subscription
OAuth (ADR 0003). That decision is retained here as historical implementation
documentation, not current setup guidance. The core is modeled on tau's three
tiers (`research/03`) and depends on **nothing
Valsi-specific**: the grammar modules call *into* it, never the reverse, and it is
**not part of AAP** — it is client-side and rides MCP / the provider transport.

```
valsi-agent-provider   transport   (cl-defgeneric over provider structs)
valsi-agent-auth       subscription OAuth (reuse Claude Code, else PKCE login)
valsi-agent-tools      typed tools + {ok,content,data,error} + scoping
valsi-agent            the provider-neutral tool-use loop + events + sessions glue
valsi-agent-session    durable append-only JSONL sessions
```

## Archived provider transport

A provider is a cl-struct dispatched by `cl-defgeneric valsi-agent-provider-request`
/ `-stream`. The brain speaks a **provider-neutral message vocabulary**
(Anthropic-shaped: `text` / `tool_use` / `tool_result` blocks) and never knows
which adapter is underneath. The archived adapters are retained for maintenance
and tests:

1. **`anthropic-oauth`** — the former primary path. Uses a subscription OAuth
   token, `Authorization: Bearer`, the `anthropic-beta:
   claude-code-20250219,oauth-2025-04-20` header, and the required Claude Code
   system-prompt preamble so Anthropic routes the request as Claude Code.
   Construct with `(valsi-agent-make-anthropic :auth 'oauth)`.
2. **`anthropic-key`** — an API-key path (`x-api-key`, or `ANTHROPIC_API_KEY`) for
   users who prefer token billing. `(valsi-agent-make-anthropic :auth 'api-key)`.
3. **`mock`** — deterministic scripted turns for ERT; the loop is fully testable
   with no network.
4. **`gptel`** — an optional, API-key-only convenience adapter, deferred (a soft
   `require` fast-follow). Never the primary path, never a dependency.

## Archived authentication

The native `valsi-agent-auth` prototype resolved credentials as follows. Normal
users authenticate in their selected terminal agent (Pi, Codex, or Claude);
this section is not production setup:

1. **Reuse Claude Code** — `CLAUDE_CODE_OAUTH_TOKEN`, then
   `~/.claude/.credentials.json`, then (macOS) the Keychain.
2. **Valsi's own store** — `~/.valsi/auth.json` (mode `600`).
3. **First-party PKCE login** — `valsi-agent-auth-login` runs an S256 flow with a
   loopback callback (or a pasted code) only if nothing above resolves.

Tokens **auto-refresh** on a 5-minute skew before a request (zero LLM tokens
consumed). All OAuth endpoint constants live in one `defconst` block in
`valsi-agent-auth.el` (they are undocumented and drift; see `research/03a`), so a
constant change degrades to "re-login", not "broken".

> **Billing caveat** (surfaced, not enforced): third-party harness use of
> subscription OAuth may draw from *extra usage*, billed per token, not against
> plan limits. Valsi states this; you decide.

## Tools

A tool is a typed schema plus an executor returning a structured result:

```elisp
(valsi-agent-tool-create :name "read_file" :description "…"
                        :args '(:type "object" :properties …)
                        :executor #'my-fn :confirm nil)
;; executor returns:
(valsi-agent-tool-result-create :ok t :content "…" :data … :error nil)
```

The `ok`/`error` split lets the loop feed failures back to the model cleanly — a
signalled error or a declined confirmation becomes a **non-OK result, never a
thrown error**, so the loop keeps going. Built-in tools: `read_file`, `list_dir`,
`grep` (read), and `apply_edit` (write, confirm-gated). Register them with
`valsi-agent-register-builtin-tools`.

## Scoping & security (control over delegation)

Every dispatch is scoped through the `valsi-agent-scope` macro, which binds the
dynamic allow-lists the tool layer consults:

```elisp
(valsi-agent-scope (:tools '("read_file" "grep")
                   :files (list "/repo/a.el" "/repo/b.el")
                   :auto-approve nil :dry-run nil)
  (valsi-agent-run :provider … :tools … :messages …))
```

- **Tool allow-list** — a tool not in `:tools` is refused before it runs.
- **File allow-list** — file tools refuse a path not in `:files`.
- **Confirm gate** — mutating tools (`:confirm t`) prompt unless `:auto-approve`.
- **Dry-run** — `apply_edit` reports the intended change without writing.

These are invariants, not options: the "control over delegation" commitment.
Inside an explicit scope, an empty or missing `:tools`/`:files` list denies
every tool/file; unrestricted access exists only for direct tool calls made
outside a scope. All four built-ins, including `grep` and `list_dir`, enforce
the same check.

## The loop

`valsi-agent-run` is **stateless** — the caller owns the transcript. It drives
turns until the model stops or `:max-turns`, executing tool calls and feeding
results back, and emits provider-neutral events on `valsi-agent-event-functions`
(`agent-start`, `turn-start`, `message`, `tool-start`, `tool-end`, `agent-end`,
`cancelled`, plus streaming deltas). A `valsi-agent-make-cancel` token, checked
between turns, interrupts a run. This event stream is what the streaming Valsi
buffer and the Sprint 7 node-diff review both consume.

## Sessions

The fallback `valsi-agent-session` persists transcripts as **append-only JSONL**
under repo-local `.valsi/sessions/` (git-ignored by default). These are legacy
native records, never a mirror or import source for Pi. Existing data is
preserved. `M-x valsi-agent-session-archive-legacy` moves the directory
byte-for-byte to `.valsi/archive/native-sessions-TIMESTAMP/`; no production Pi
session or credential is inspected or changed.

## Instruction loading

`valsi-agent-load-instructions` assembles a system-context string from
`AGENTS.md` / `CLAUDE.md` / `.valsi/instructions.md`, walking up from the working
directory with **nearest-wins** precedence. This is the minimal Sprint-6 loader;
it is swapped for the grammar-aware `valsi-instruction` version in Sprint 7.

## Acceptance

- **Mock (CI):** ERT drives the loop through a scripted tool call to completion
  deterministically, with no network (`valsi-test-agent-mock-loop`).
- **Historical live gates:** the former native Anthropic OAuth check was
  superseded by Sprint 13's Pi/Codex subscription acceptance. ADR 0006 retains
  the ownership result—credentials stay with the CLI—but moves login and resume
  back to the CLI's own terminal UI.

# Valsi v1.0 QA matrix

The manual acceptance matrix for v1.0, complementing the automated ERT suite
(`make check`) and the AAP conformance suite (`make conformance`). Automated
tests prove the pure cores; this matrix is the human pass over the *interactive*
surface — font-lock, dispatch, views, and the agent bridge — that batch tests
cannot fully exercise.

## How to run

```
guix shell -D -f valsi.scm -- make check                            # 210 ERT
guix shell nss-certs emacs emacs-markdown-mode -- make conformance # 12 AAP
guix shell nss-certs emacs emacs-markdown-mode -- make run         # demo Emacs
```

In the demo Emacs, `valsi-global-mode` auto-activates on markdown; `C-c n`
opens the per-artifact keymap and `C-c n m` the transient menu.

## Automated coverage (green gate)

| Suite | What it proves | Count |
|---|---|---|
| `make check` | artifact grammars and the transitional Sprint 13 native/Pi harness contract: pinned 0.80.6 golden JSONL traces, drift and crash recovery, session projection, AAP stdio, extension startup, and structured review seams. ADR 0006 preserves this as migration evidence; it is not proof of the terminal-application UX introduced in Sprint 14. | 210 |
| `guix build -f valsi.scm` | the same 210-test contract runs inside the isolated package derivation, including packaged Pi launcher and live RPC/extension/session-list startup | 210 |
| `make conformance` | the AAP wire contract any implementation must pass | 12 |
| `make test-extension` / `make guix-test-extension` | Bun runs fail-closed Pi tool/file policy, symlink escapes, bash conservatism, approval failure, dry-run, correlated AAP client, authentication bridge, and projected SessionManager bridge | 23 |
| `valsi-perf-test` | 2000-task parse < 5 s, serialize round-trip preserves every node, 20× reparse loop < 15 s | 3 |

**Definition of done per task (Q-track):** green ERT + docstring + CHANGELOG note.

## Per-family manual matrix

Legend: ✅ verified · — n/a. Each row is a manual check against a real corpus
file (`test/fixtures/**`) in the demo Emacs.

Historical Sprint 13 evidence as of 2026-07-30: Pi subscription login, smoke,
and project-scoped restart/resume passed through the native RPC prototype. ADR
0006 preserves that ownership/runtime evidence but supersedes its UI. Sprint
14's Eat terminal, hub refresh, handoff, and window behavior require the
application checks below; the historical pass is not substituted for them.

### Plan / tasks (flagship)

| Check | Rung | Steps | Expect |
|---|---|---|---|
| Dialect detect | 2 | open each `plan-tasks/*` | header-line shows the right dialect |
| Font-lock | 2 | look at a tasks file | state-colored boxes, dimmed done, dep/trace badges |
| Navigate | 3 | `next/previous-task`, `goto-id`, `occur-state` | point lands correctly |
| Toggle / block | 3 | `toggle`, `block` on a task | open→in-progress→done cycles; block adds child |
| Structure edit | 4 | `insert-task`, `split-task`, `renumber` | ids + `depends on` refs rewrite in one undo |
| Lint / flymake | 4 | file with a dangling dep + a cycle | both flagged live |
| Coverage / stale | 5 | multi-file spec dir | requirements↔tasks table; stale rows flagged |
| Dashboard | 5 | `valsi-plan-dashboard` | cross-file agenda; `RET` visits |
| Dispatch (agent) | 6 | `dispatch-next` on mock | task runs; edit lands as a node-diff review |

### Instruction (AGENTS.md / CLAUDE.md)

| Check | Rung | Steps | Expect |
|---|---|---|---|
| Scope tree | 2 | open a scoped AGENTS.md | heading-scope + glob predicate recognized |
| Effective-at-point | 3 | `effective-at-point` in a nested dir | nearest-wins rules + glob shown |
| Import graph | 3 | file with `@imports` | transitive graph; `[missing]` + cycle-guarded |
| Lint | 3 | dangling `@import`, unscoped frontmatter | both flagged |
| Sync | 4 | `sync` one source → peer targets | idempotent managed region mirrored |

### Prompt-file (SKILL.md / subagents / commands)

| Check | Rung | Steps | Expect |
|---|---|---|---|
| Type discrimination | 2 | open a SKILL.md, an agent, a command | correct per-type vocabulary |
| Field table | 2 | `dashboard` | typed fields with required/known/? |
| Validate | 3 | skill missing `description` | missing-required + unknown-key warnings |
| Complete | 3 | `complete` | offers a known key not yet present |
| Test-fire | 4 | `test-fire` with a query | keyword-overlap verdict |
| Scaffold | 5 | `scaffold` a dir | SKILL.md + scripts/references/assets |

### Memory (index + record)

| Check | Rung | Steps | Expect |
|---|---|---|---|
| Kind detect | 2 | open MEMORY.md vs a record | index vs record; record kind read |
| Dashboard | 2 | `dashboard` on MEMORY.md | pointer table; `RET` visits |
| Follow / backlinks | 3 | on a `[[link]]` / pointer | opens target; backlinks listed |
| Dedupe | 4 | index with two pointers to one file | duplicate candidates reported (no merge) |
| Stale-check | 4 | pointer to a deleted file, dangling `[[link]]` | both reported |

### Cross-artifact graph (capstone)

| Check | Steps | Expect |
|---|---|---|
| Unified edges | `valsi-graph` in the project | imports, links, index, path, trace, phase edges in one table |
| Phase successor | on PLAN.md | `Sprint N → Sprint N+1` edges present |
| Navigate | `RET` on a row | opens the source artifact |
| Pluggable | `valsi-graph-register-edge-source` a fn | its edges appear with no core change |

### Artifact application and terminal agents

| Check | Steps | Expect |
|---|---|---|
| Application hub | `M-x valsi` | project artifact families, warnings, recent/current artifacts, and agents appear without a generic file-tree clone |
| Responsive matrix | capture hub and `PLAN.md` at 80×24, 100×30, 140×40, and 180×50 | hub metadata degrades deliberately; sidebar never makes source/terminal unusable |
| Direct application keys | in hub/sidebar use `n`, `p`, `t`, `TAB`, `RET`, `g`, `/`, `?`, `s`, and `c` | actions need one key in read-only Valsi buffers; editable source and terminal text remain untouched |
| Refresh stability | fold a family, move point, scroll, then edit/save externally | fold state, semantic point, and window start survive the live redraw |
| Theme inheritance | capture Modus Operandi and a dark Modus theme | hierarchy remains legible and warnings alone receive attention color |
| Live refresh | edit/save an artifact, create one externally, and have an agent modify one | affected hub rows update after debounce/notification; `g` reconciles all state |
| Unsaved conflict | modify a buffer, then change its file externally | buffer is never overwritten; hub marks the conflict |
| Project navigation | use hub file/directory/tree actions | delegates to `project-find-file`, `project-dired`, or configured tree package |
| Eat terminal | `M-x valsi-agent` | a real terminal buffer starts the configured CLI at the canonical project root; no literal ANSI/OSC text |
| CLI fidelity | exercise prompt editing, Enter, Escape, arrows, `C-c`, `C-d`, slash commands, selection/copy | keys retain the selected CLI's normal behavior; Valsi prefix remains reachable |
| Independent entry | open hub, artifact index, and terminal separately | each works without requiring a fixed workspace layout |
| Composed entry | run `valsi-agent-with-artifacts` | large terminal plus small artifact index; leaving restores prior windows |
| Agent capability | prompt without attaching files | agent may read/search/edit/run project commands according to its own sandbox |
| Explicit handoff | invoke send/reference on an artifact task | stable path/task reference is inserted into the terminal prompt and is not auto-submitted |
| Backend degradation | select Pi, Codex, Claude, and a custom CLI | terminal basics work; unsupported structured/session features are visibly unavailable, never scraped |
| Structured review | complete a dispatched task with and without a structured callback | callback can open node review; terminal-only backend requires explicit review and never infers completion from screen text |
| Pi subscription login | start Pi in Eat and use Pi's own login | OAuth/browser/device interaction renders correctly; credential stays exclusively with Pi |
| Pi restart/resume | complete a recognizable Pi turn, restart Emacs, reopen project agent | Pi resumes its authoritative session through its own CLI behavior |
| Pinned runtime | `guix shell -f valsi.scm -- pi --version` | exactly `0.80.6` |
| Billing wording | inspect login/help documentation | Codex is the included path; Claude extra-usage caveat is present |

## Degradation spot-checks (the invariant)

- Disable `valsi-artifact-minor-mode` on any file → buffer + file byte-identical.
- Open a malformed file of each family → still opens, outline + narrow work, no
  error; higher-rung commands are simply absent (gated), never crash.
- A grammar registered at runtime (`grammar/register`) → symbols appear with no
  restart (hot-reload invariant).

## Sign-off

v1.0 ships when: `make check` + `make conformance` green on the Emacs floor
(29.1) and current (30.2); every row above ✅ on a manual pass; `make run`
launches clean; and `guix shell -f valsi.scm -- make check` reproduces green.

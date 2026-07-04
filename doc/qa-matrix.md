# Valsi v1.0 QA matrix

The manual acceptance matrix for v1.0, complementing the automated ERT suite
(`make check`) and the AAP conformance suite (`make conformance`). Automated
tests prove the pure cores; this matrix is the human pass over the *interactive*
surface — font-lock, dispatch, views, and the agent bridge — that batch tests
cannot fully exercise.

## How to run

```
guix shell nss-certs emacs emacs-markdown-mode -- make check       # 120 ERT
guix shell nss-certs emacs emacs-markdown-mode -- make conformance # 12 AAP
guix shell nss-certs emacs emacs-markdown-mode -- make run         # demo Emacs
```

In the demo Emacs, `valsi-global-mode` auto-activates on markdown; `C-c n`
opens the per-artifact keymap and `C-c n m` the transient menu.

## Automated coverage (green gate)

| Suite | What it proves | Count |
|---|---|---|
| `make check` | recognizers, per-dialect parse, capability advertisement, hot-reload, JSON round-trip, `parse→serialize` identity on the whole corpus, agent mock loop, all four families | 120 |
| `make conformance` | the AAP wire contract any implementation must pass | 12 |
| `valsi-perf-test` | 2000-task parse < 5 s, serialize round-trip preserves every node, 20× reparse loop < 15 s | 3 |

**Definition of done per task (Q-track):** green ERT + docstring + CHANGELOG note.

## Per-family manual matrix

Legend: ✅ verified · — n/a. Each row is a manual check against a real corpus
file (`test/fixtures/**`) in the demo Emacs.

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

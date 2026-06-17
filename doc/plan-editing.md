# Plan/tasks — structure editing & lint

The plan/tasks grammar (`valsi-plan`) is a **write-through** grammar: beyond
reading and navigating a plan, Valsi edits its structure while keeping the file
ordinary markdown. Every command below is dialect-aware where it matters and
leaves the buffer diffable — the descriptive-grammar invariant (ADR 0001) holds:
disabling Valsi leaves the file byte-identical, and edits change only what they
claim to.

All commands are exposed through the client keymap / `transient` (`C-c n`) and
advertised via the capability ladder — they appear only when the resolved
structure supports them.

## State

| Command | Effect |
|---|---|
| `valsi-plan-toggle` | Cycle the task at point: open → in-progress (`- [-]`) → done → open. |
| `valsi-plan-complete-with-children` | Mark the task **and every descendant task** done (Kiro interior tasks). Length-preserving, one undo group. |
| `valsi-plan-block` | Record a `- Blocked: <reason> (<date>)` child bullet under the task. |

## Structure

| Command | Effect |
|---|---|
| `valsi-plan-insert-task` | Insert a new open task after point, numbered in the buffer's dialect (`Tnnn` for Spec-Kit, next integer for Kiro, unnumbered otherwise). |
| `valsi-plan-split-task` | Split the task at point in two — text after point becomes a new numbered task below. |
| `valsi-plan-promote-step` | Turn a plain step bullet (`- text`) into a full task with a new dialect id. |
| `valsi-plan-demote-task` | Turn a task into a plain step bullet, dropping the checkbox and id. |
| `valsi-plan-move-task-up` / `-down` | Move a task **and its whole subtree** past its sibling. Refuses a move that would put a task on the wrong side of a dependency (the dep-order guard). |

### Renumbering

`valsi-plan-renumber` normalizes Spec-Kit `Tnnn` ids to sequential document
order and rewrites **every id and every `(depends on …)` reference** in a
**single undo group** — the answer to positional-id fragility. It reads each
original token and writes its replacement in one pass, so overlapping id spaces
(e.g. `T009 → T002` while a `T002` already exists) never collide. Sub-ids like
`T001.1` are matched as whole tokens and left untouched unless they are
themselves top-level ids.

It **refuses on non-Spec-Kit dialects**: in Kiro-style plans the positional id
*is* the meaning, so silently renumbering would corrupt intent.

### Dependencies

`valsi-plan-add-dep` adds a `depends on` reference to the task at point,
merging into an existing `(depends on …)` group when present. It **refuses to
create a cycle**: before adding `A depends on B`, it checks whether `B` already
transitively depends on `A` and aborts if so.

## Lint

`valsi-plan-lint` reports plan health in a `*valsi-plan-lint*` buffer. The
structural checks are computed by the pure `valsi-plan--lint-collect` (no buffer,
no filesystem) and cover:

- **duplicate ids**
- **dangling deps** — a `depends on` reference to an id that does not exist
- **dependency cycles** — a task that transitively depends on itself
- **interior-state contradictions** — a task marked done whose effective state
  (derived from its children) is not done
- **unknown state chars** — a checkbox char outside the recognized set

On top of the pure checks, the command adds two context-dependent ones:

- **missing manifest files** — a done task whose backtick path-refs no longer
  resolve on disk
- **placeholders** — `TXXX`, `NEEDS CLARIFICATION`, `[FEATURE NAME]`

### Live diagnostics (flymake)

`valsi-plan-flymake-setup` registers a [flymake](https://www.gnu.org/software/emacs/manual/html_node/flymake/)
backend that surfaces the same findings inline as you edit, anchored to the
offending task line. It reuses `valsi-plan--lint-collect` and the missing-file
check, so the batch report and the live diagnostics never drift.

## Invariants

- **One undo group** — `renumber`, `complete-with-children`, `split`, and
  `move` each wrap their edits in `atomic-change-group`, so a single undo
  reverts the whole operation.
- **Descriptive** — no command rewrites text it did not target; the
  `parse → serialize` identity holds across the corpus (see
  `valsi-test-roundtrip-identity`).

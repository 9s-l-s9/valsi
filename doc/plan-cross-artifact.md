# Plan/tasks — cross-artifact navigation & health (rung 5)

At rung 5 the plan grammar stops treating a `tasks.md` as an island and starts
resolving its **outbound references** — path-refs, requirement traces, story
tags — and reporting **health across files**. These commands need only the
structure a plan already carries; they degrade to no-ops (and are unadvertised)
when it is absent.

## Trace resolution

`valsi-plan-follow-trace` (also bound as the generic `follow`) resolves the trace
on the task line at point, trying in order:

1. **Backtick path-ref** — `` `app/models/user.rb:42` `` → visit the file, jump
   to the line.
2. **Requirement trace** — `_Requirements: 1.2, 2.1_` → open the sibling
   `requirements.md` (or `spec.md`) and jump to the first matching EARS item
   (`1.2`). The sibling is discovered next to the current file (the Kiro
   `.kiro/specs/<name>/{tasks,requirements,design}.md` convention).
3. **Story tag** — `[US1]` → open `spec.md` and jump to the user story.

Requirement/story ids are matched as **whole tokens** (`\_<1.1\_>`), so `1.1`
never matches inside `11.1`.

## Coverage

`valsi-plan-coverage` renders a **requirements ↔ tasks** table: one row per
requirement id, the number of tasks tracing to it, and their ids. The row set is
the union of

- requirements **referenced** by tasks (from each task's `:traces`), and
- requirements **defined** in the sibling `requirements.md`, scraped as
  `n.m`-numbered acceptance criteria.

Requirements with **zero covering tasks** are highlighted — the gap between what
the spec asks for and what the plan schedules.

## Staleness

`valsi-plan-stale-check` flags tasks whose work may have drifted from the plan:
for each task path-ref that resolves on disk, it compares the target file's
modification time against the plan file's. A target **newer than the plan** means
the code moved after the task was last written — the task is *trailing its
target* and worth review. Results appear in `*valsi-plan-stale*`.

> Modification-time is the portable signal used by default; a git-log-based
> variant (last-commit time per file) is a natural refinement where the tree is
> a clean checkout.

## Dashboards (rung 5, cross-file)

`valsi-plan-dashboard` is a `tabulated-list` agenda over **every** plan artifact
in the project — `PLAN.md`, `specs/*/tasks.md`, `.kiro/specs/*/tasks.md`,
`.planning/*.md` — showing each file's dialect, done/total, percent complete, and
work-in-progress count. `RET` visits the file on the row.

`valsi-plan-next-actionable` is the **agent-handoff primitive**: it jumps to the
first open task whose dependencies are all satisfied (falling back to the first
open task in document order below the rung). This is the query the agent
bridge will call to pick the next task to dispatch.

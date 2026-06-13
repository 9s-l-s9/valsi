# Valsi plan/tasks commands — v0.1 stubs

Command catalog over `design/plan-grammar.md`, pre-implementation. Each stub:
purpose, grammar requirement (degradation rung, see spec §4), behavior,
fallback below the rung. Names use `valsi-plan-` prefix; final keymap TBD, but
the intended interaction grammar is Emacs-native: commands act on
*task-at-point* (or region), prefix arg widens to subtree, a transient menu
(`valsi-plan-menu`) is the discoverable entry point, and every buffer-mutating
command is undoable + shows a diff when invoked on agent output.

## A. Navigation & query (read-only, rung 2+)

- `valsi-plan-next-task` / `valsi-plan-previous-task` — motion between task
  lines; with prefix arg, only open tasks. Rung 2.
- `valsi-plan-goto-id` — completing-read over ids → jump. Rung 3;
  fallback: complete over description text.
- `valsi-plan-next-actionable` — first open task whose deps are all satisfied
  and whose group isn't blocked by an unfinished blocking phase. **The agent
  handoff primitive.** Rung 5; fallback: first open task in document order.
- `valsi-plan-occur-state` — occur-style buffer of tasks filtered by state /
  tag / story. Rung 2.
- `valsi-plan-info-at-point` — echo/posframe summary of task: state, deps
  (with their states), traces, files, verification presence. Rung 3.

## B. State (rung 2+)

- `valsi-plan-toggle` — cycle open → in-progress → done on task at point.
  On an interior task, offer to apply to children (Kiro semantics).
- `valsi-plan-complete-with-verification` — if the task has R10 verification,
  run the assertions in compilation-mode; mark done only on pass, otherwise
  show failure and offer mark-blocked. Rung 6; fallback: plain toggle with a
  "no verification defined" note.
- `valsi-plan-block` — mark blocked with a reason (stored as a child bullet
  `- Blocked: reason (date)`, a construct to *add* to the grammar and watch
  whether agents preserve it).
- `valsi-plan-progress` — mode-line / header-line progress per group and file
  (n/m done, current in-progress task). Rung 2.

## C. Structure editing (rung 3+ mostly)

- `valsi-plan-insert-task` — insert after point/at end of group; assigns next
  id and emits in the file's dialect profile. Rung 3; fallback: bare checkbox.
- `valsi-plan-split-task` — turn task into interior task + subtasks from its
  step bullets, or split description at point. Renumber-aware. Rung 4.
- `valsi-plan-promote-step` / `valsi-plan-demote-task` — step bullet ↔ checkbox
  subtask. Rung 4.
- `valsi-plan-move-task-up/down` — reorder within group; warns (or refuses
  with prefix arg override) when the move violates dep order. Rung 5;
  fallback: plain move.
- `valsi-plan-renumber` — normalize ids after edits; rewrites all dep/trace
  refs atomically (single undo group) — the answer to Kiro's positional-id
  fragility. Rung 3.
- `valsi-plan-add-dep` — read two tasks (at point + completing-read), emit
  dialect-shaped dep; refuse cycles. Rung 5.

## D. Lint & health (rung 3+)

`valsi-plan-lint` — flycheck-style overlay diagnostics:
- dangling dep/trace refs; duplicate ids; dep cycles
- template placeholders left in (`TXXX`, `[FEATURE NAME]`, `NEEDS CLARIFICATION`)
- interior task whose checkbox state contradicts children
- done task whose manifest files don't exist (R9) — evidence check
- unknown checkbox state chars (surfaced, not auto-fixed)

Each diagnostic carries a fix action where mechanical (renumber, remove
placeholder section).

## E. Cross-artifact (rung 5+)

- `valsi-plan-follow-trace` — on `_Requirements: 2.1_` → the requirement
  heading in requirements.md/spec.md; on a path-ref → file(:line); on a story
  tag → the user story in spec.md. Rung 5.
- `valsi-plan-coverage` — table view: requirements ↔ tasks; rows with zero
  tasks highlighted. Rung 5.
- `valsi-plan-stale-check` — if spec/requirements are newer (git mtime/log)
  than tasks.md, flag tasks whose trace targets changed since. Rung 5.
- `valsi-plan-dashboard` — tabulated-list across all plan artifacts in the
  project (`specs/*/tasks.md`, `.kiro/specs/*/tasks.md`, PLAN.md…): file,
  progress, in-progress task, blocked count, staleness. The org-agenda
  analogue. Rung 2 per file.

## F. Agent interaction (the point of it all)

- `valsi-plan-dispatch-task` — hand task-at-point to the agent. The grammar
  assembles the context bundle: task + group meta + file manifest +
  read-first refs + trace targets + verification block; the harness scopes
  the agent to the manifest files where present. Rung 3 (richness grows with
  rung).
- `valsi-plan-dispatch-next` — `next-actionable` + `dispatch-task`; with
  prefix arg, loop until blocked or a checkpoint group boundary. Rung 5.
- `valsi-plan-review-update` — after an agent edits the plan file: structural
  diff at the node level ("T014 open→done; T017 added; Phase 3 checkpoint
  note edited") instead of a raw text diff; accept/reject per node. This is
  write-through-grammar made concrete. Rung 3.
- `valsi-plan-replan-region` — send region/subtree + an instruction
  ("split this phase", "add verification steps") and apply the result as a
  reviewable node diff. Rung 2.
- `valsi-plan-distill` — from a finished session/transcript, ask the agent to
  propose plan updates (states, new tasks, blocked notes) as a node diff.
  Companion of the AGENT.md `promote-from-session` idea.

## G. Dialect & interop

- `valsi-plan-detect-dialect` — show detection scores; override per-file
  (file-local variable).
- `valsi-plan-convert` — rewrite the file into another profile (e.g. Kiro
  decimals → opaque `Tnnn` ids), updating all refs. Explicitly lossy where
  target lacks a construct — report what was dropped.
- `valsi-plan-scaffold` — new plan/tasks file in the chosen profile from group
  titles the user gives; no template bureaucracy beyond what the profile emits.

## Implementation notes (for the Emacs step)

- Parser: markdown tree-sitter grammar for the outline + line recognizers as
  a thin elisp layer producing the node tree with markers; re-parse
  incrementally on after-change (regions are small).
- Views: font-lock from node table (state-colored checkboxes, dimmed done
  tasks, dep badges); dashboard/coverage via tabulated-list-mode; diagnostics
  via flymake backend.
- `valsi-plan-minor-mode` on top of markdown-mode (not a major mode — the
  file must stay editable as ordinary markdown at all times, per the
  degradation principle).
- Priority order for v0 implementation: parser + font-lock + toggle +
  next-actionable + lint + review-update. Dispatch commands come once the
  general Valsi agent bridge exists; review-update can be developed against
  hand-made diffs before that.

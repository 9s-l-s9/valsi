# Plan × agent — dispatch, verify, review (rung 6)

This is the payoff: the flagship grammar drives the agent core. A task becomes a
**scoped, verifiable unit of work**, and the agent's edits land as a
**reviewable node-diff** — never a silent overwrite (the "control over
delegation" invariant). The bridge (`valsi-plan-agent`, `valsi-plan-review`) is
client-side and rides the agent core; it is *not* part of AAP.

## Dispatch

`valsi-plan-dispatch-task` (on a task line):

1. **Assembles a context bundle** (`valsi-plan-context-bundle`) — the task id and
   description, its enclosing group/phase, its file manifest (path-refs on the
   task and in its `**Files:**` meta), dependencies, requirement traces, step
   sub-bullets, and the `**Verify:**` block.
2. **Renders a dispatch prompt** (`valsi-plan-bundle->prompt`) from the bundle.
3. **Scopes the agent to the manifest files** — `valsi-agent-scope :files …` — so
   the agent can only touch what the task declares.
4. **Runs the loop** against the configured provider (subscription OAuth by
   default; set `valsi-plan-agent-provider` to override) with the built-in tools
   and the nearest-wins instruction context.

`valsi-plan-dispatch-next` composes `next-actionable` with `dispatch-task`: it
jumps to the first open task whose dependencies are satisfied and dispatches it —
the agent-handoff loop step.

## Verify

`valsi-plan-run-verification` extracts the first backtick command from the task's
`**Verify:**` meta and runs it in `compilation-mode`.

`valsi-plan-complete-with-verification` runs that command and marks the task done
**only on success** (exit 0); on failure it offers to `block` the task. This
closes the loop: a task is not "done" until its own stated check passes.

## Review — the node-diff

After an agent edits a plan, `valsi-plan-review-update` shows a **task-level
structural diff** (`valsi-plan-diff`) rather than a raw text diff:

```
Valsi plan review  [t] toggle  [a] accept-all  [r] reject-all  [RET] apply  [q] quit

  [x] ~ - [ ] T014 …  =>  - [x] T014 …        ; state open -> done
  [x] + - [ ] T017 new task                    ; added
  [x] ~ - [ ] T009 …  =>  - [ ] T009 … edited  ; description changed
```

Changes are **keyed by task id**, so the diff is stable under reordering and
robust to the agent rewriting whole regions. Each row is accepted or rejected
independently (`t`); `RET` applies only the accepted ones (`valsi-plan-apply-changes`).

Two invariants back the UI:

- **Reject-all restores the file byte-identically** — applying no changes returns
  the original content unchanged (`valsi-test-plan-review-reject-all`).
- **The diff enumerates exactly the changed tasks** — no more, no less
  (`valsi-test-plan-node-diff`).

## Distill

`valsi-plan-distill` turns a finished agent session into plan updates: it scans
the session transcript for task-id mentions and proposes a **done-marking
node-diff** (`valsi-plan-distill-done`) for review — so the plan stays the source
of truth after a working session, without hand-editing checkboxes.

## Trying it

Open a real Spec-Kit `specs/NNN/tasks.md`, put point on the next actionable task,
and `M-x valsi-plan-dispatch-next`. When the agent reports back, `M-x
valsi-plan-review-update` on its proposed edit, accept the node changes you want,
and `RET`. Then close Valsi and confirm the file on disk is still ordinary
markdown a plain editor reads unchanged (the M6 acceptance).

> The live end-to-end run needs a provider (a Claude subscription via OAuth, or an
> API key). The bundle assembly, prompt rendering, verify extraction, node-diff,
> apply, and distill are all pure and covered by ERT with no network.

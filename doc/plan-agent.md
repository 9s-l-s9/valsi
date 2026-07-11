# Plan × agent — dispatch, verify, review (rung 6)

This is the payoff: the flagship grammar can hand a structured task to the
user's selected terminal agent. A task remains a **context-rich, verifiable unit
of work**, and proposed task-state changes land as a **reviewable node-diff**,
never a silent overwrite. The bridge is client-side and is *not* part of AAP.

## Dispatch

`valsi-plan-dispatch-task` (on a task line):

1. **Assembles a context bundle** (`valsi-plan-context-bundle`) — the task id and
   description, its enclosing group/phase, its file manifest (path-refs on the
   task and in its `**Files:**` meta), dependencies, requirement traces, step
   sub-bullets, and the `**Verify:**` block.
2. **Renders a dispatch prompt** (`valsi-plan-bundle->prompt`) from the bundle.
3. **Adds effective nearest-wins instructions and manifest file hints** to the
   prompt. The manifest is context, not a filesystem allow-list; a normal
   coding agent may inspect other project files when needed.
4. **Hands the prompt to the project agent terminal**. Review-before-submit is
   the default: Valsi inserts the prompt into stock Pi, Codex CLI, Claude Code,
   or a configured custom CLI without pretending to own that CLI's transcript
   or submission keys. A separate explicit command may submit immediately when
   the backend supports safe input injection.

Pi can provide richer artifact resolution through the Valsi extension and AAP.
Other CLIs may use a future MCP/AAP face. Valsi never scrapes terminal output to
infer that a task completed; the user invokes node review explicitly.

`valsi-plan-dispatch-next` composes `next-actionable` with `dispatch-task`: it
jumps to the first open task whose dependencies are satisfied and prepares the
agent handoff. If all open tasks are blocked, it reports that and does not
prepare a prompt.

## Verify

`valsi-plan-run-verification` extracts the first backtick command from the task's
`**Verify:**` meta and runs it in `compilation-mode`.

`valsi-plan-complete-with-verification` runs that command and marks the task done
**only on success** (exit 0); on failure it offers to `block` the task. This
closes the loop: a task is not "done" until its own stated check passes.

## Review — the node-diff

After an agent edits a plan, `valsi-plan-review-update` prompts for the proposed
plan file and shows a **task-level
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

`valsi-plan-distill` is retained for structured backends that explicitly return
a task result. It proposes a **done-marking node-diff**
(`valsi-plan-distill-done`) for review. It must not scrape terminal cells, scan
private session files, or create a parallel transcript. With a terminal-only
backend, the user opens node review explicitly.

## Trying it

Open a real Spec-Kit `specs/NNN/tasks.md`, put point on the next actionable
task, and run `M-x valsi-plan-dispatch-next`. Review the prepared prompt in the
agent terminal and submit it using the CLI's normal key. After the work and
verification, accept or reject any structured node proposal. The file on disk
remains ordinary Markdown a plain editor reads unchanged.

> Pi is the default tested terminal agent; OpenAI Codex via a ChatGPT
> subscription is the no-API-key acceptance path. Credentials and sessions stay
> with Pi. Bundle assembly, prompt rendering, verify extraction, node-diff, and
> apply remain pure and covered by ERT with no network.

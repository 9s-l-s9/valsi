# Multi-agent terminal model

Status: design for later implementation

This document refines the multi-agent direction in ADR 0006.  Valsi manages
named terminal instances around independent agent CLIs; it does not become an
agent runtime.  The model is deliberately small enough to fit the existing
project hub and `valsi-terminal-agent-instance`.

## 1. Instance record

An instance is identified by `(project-id, name)`.  Names are unique only
inside one logical project and are chosen by the user, for example `primary`,
`reviewer`, or `docs`.

```text
terminal-agent-instance
  project-id       stable logical project identity
  name             user-visible identity, unique within project-id
  backend          pi | codex | claude | custom
  capability       snapshot of declared Valsi integration capability
  task             optional stable artifact/task reference
  worktree         canonical execution workspace
  buffer           live Eat buffer, never serialized
  status           process or structured-backend status
  status-source    process | backend | user
```

`project-id` is the canonical project root for ordinary projects.  For Git
worktrees it is derived from the repository's common Git directory, so the
main checkout and linked worktrees appear in the same Valsi hub.  It is an
opaque key, not a directory in which commands necessarily run.

`worktree` is always the canonical directory used as the terminal's
`default-directory`.  The initial single-agent implementation sets
`project-id` and `worktree` to the same root.  Keeping both concepts separate
prevents later worktree support from changing the meaning of an existing
field.

`capability` describes Valsi integration, not the coding ability of the CLI.
The initial values are:

- `terminal`: stock terminal interaction and plain-text artifact references;
- `full`: the tested Pi extension/AAP integration in addition to the terminal.

Capabilities are snapshotted when an instance starts.  A future structured
backend may advertise a set instead, but unavailable features must remain
unavailable rather than being emulated through terminal scraping.

`task` is a semantic association such as `@task:T302 from PLAN.md`.  It helps
the hub and collision checks; it does not constrain the CLI's filesystem
access.  An agent continues to have the normal project access of its terminal
session.

Status is coarse.  Process state may establish `starting`, `running`, or
`exited`.  `idle`, `busy`, or `blocked` may be shown only when a structured
backend reports them or the user explicitly sets them.  Valsi must not infer
activity by parsing terminal cells, prompts, or transcripts.

## 2. Ownership and persistence

The in-memory registry owns names, buffer/process handles, and current
metadata.  A later project-local metadata file may persist only:

```text
name, backend, capability, task, worktree, last coarse status
```

Process handles and buffers are never persisted.  The following data is
explicitly outside this model:

- prompt or transcript text;
- provider credentials, tokens, or login state;
- model/session history owned by Pi, Codex, Claude, or another CLI;
- terminal screen contents or screen-scraping caches;
- invented manager/worker queues or messages.

Restarting Valsi may offer to reopen declared instances, but each CLI remains
responsible for resuming its own session.

## 3. Hub and switching

The existing Agents section grows into a compact table:

```text
State     Name       Backend  Capability  Task    Workspace       Warning
running   primary    pi       full        T302    main            overlaps reviewer
running   reviewer   codex    terminal    T302    wt/review       clean
blocked   docs       claude   terminal    T305    wt/docs         clean
```

Selecting a row focuses its real Eat buffer.  `valsi-agent-switch` completes
over the same project-scoped registry.  Starting an already-live
`(project-id, name)` is an error; changing backend or workspace requires
stopping that instance or choosing another name.  Backend switching never
migrates a private CLI session.

Hub refresh reconciles buffer/process liveness and Git evidence.  It does not
poll or inspect terminal output.  Missing worktrees and exited processes remain
visible as actionable states until the user removes or restarts the record.

## 4. Collision model

Warnings are evidence, not locking.  Valsi never claims that a warning makes
concurrent writes safe.

Collision checks proceed from cheapest to most specific:

1. **Workspace overlap:** two live writing instances have equal canonical
   `worktree` directories.  This is always a high-severity warning.
2. **Nested workspace overlap:** one canonical workspace contains the other.
   This is a high-severity warning unless both instances are explicitly
   read-only.
3. **Changed-file overlap:** for worktrees belonging to the same Git
   repository, intersect their tracked and untracked changed-file paths as
   reported by Git.  A non-empty intersection lists the colliding paths.
4. **Task overlap:** equal task associations in different worktrees are
   informational.  They become a warning only when changed-file evidence also
   overlaps.

The model initially treats terminal agents as writers.  A future structured
capability may explicitly declare `read-only`; Valsi must not guess this from
the task label or transcript.

File sets are refreshed on hub refresh and after known saves.  They are
advisory snapshots: external writes can race with them.  Unsaved Emacs buffers
continue to use the application's existing conflict handling and are never
overwritten.

## 5. Git-worktree isolation

Concurrent writing agents should normally run in separate linked Git
worktrees.  Creation is an explicit user action:

```text
name → branch → worktree directory → confirmation → git worktree add
```

Valsi validates that the target is outside another registered workspace, that
the branch/worktree pairing is unambiguous, and that the resulting worktree
belongs to the same Git common directory as `project-id`.  It then starts the
CLI with that worktree as `default-directory`.

Valsi does not automatically move an existing process between worktrees.
Removing a worktree is also explicit, is refused while an associated process
is live, and delegates safety checks to Git.  Branch creation, merge, review,
and cleanup remain visible Git operations; Magit may provide their UI.

Non-Git projects still support multiple named terminals, but only
workspace-overlap warnings are available and separate-directory isolation is
manual.

## 6. Coordination boundary

The first multi-agent workflow is peer coordination:

1. start or switch named terminal instances;
2. associate each instance with a task and workspace;
3. exchange stable artifact references through explicit, non-submitting
   handoff;
4. inspect artifacts and Git changes in native Emacs views;
5. resolve warnings and review/merge through Git.

There is no synthetic manager, worker, delegation, mailbox, or cross-agent
chat protocol.  Those concepts may be added only when an agent backend exposes
structured operations with defined identity, delivery, acknowledgement, and
failure semantics.  Blindly typing into another terminal or scraping its
screen is not such a protocol.

## 7. Implementation sequence

Later implementation should preserve this order:

1. split logical `project-id` from execution `worktree`;
2. expose task/status mutation commands and richer hub rows;
3. add overlap warnings based on canonical paths;
4. discover Git common-directory identity and changed-file intersections;
5. add explicit worktree create/start/stop/remove flows;
6. add persistence only if reopening named declarations proves useful.

Each step must leave stock terminal use intact.  Structured orchestration is
not a prerequisite for any step above.

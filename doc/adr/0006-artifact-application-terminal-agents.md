# 6. Make Valsi an artifact application around terminal-native agents

Date: 2026-07-30

## Status

Accepted.

This decision supersedes ADR 0005 where it assigns Valsi ownership of a native
chat/composer, transcript rendering, provider login UI, session UI as a required
path, per-prompt file policy, and tool approvals. ADR 0005 remains in force for
the decisions not to reimplement or fork Pi, to keep credentials and sessions
with the agent runtime, to use AAP only for artifacts, and to package a tested
Pi release reproducibly.

## Context

The Pi RPC integration proved subscription authentication, streaming,
project-scoped session resume, structured extension calls, and an Emacs-native
prompt dashboard. It also showed that a polished native agent frontend makes
Valsi responsible for a second implementation of prompt editing, transcript
rendering, tool output, authentication dialogs, model/session controls,
approvals, and compatibility shims. Attachment-derived file permissions further
made ordinary coding less capable than using the agent in a regular terminal.

That work crossed Valsi's intended product boundary. Valsi's differentiated value
is its grammar-aware treatment of plans, instructions, skills, memories,
decisions, and related artifacts. Pi, Codex CLI, and Claude Code already provide
maintained interactive agent applications.

An Eat prototype ran stock Pi's full-screen TUI inside Emacs without the literal
OSC escape sequences produced by the earlier ordinary process buffer. It
restored the existing Pi conversation and displayed Pi's prompt, tools,
subscription usage, model, and status correctly. A real terminal emulator can
therefore reuse the agent UI rather than emulate it.

Valsi also needs a coherent application identity. Magit is the closer model:
one project hub, dedicated drill-down buffers, a command vocabulary, and
predictable return behavior without owning the frame or replacing Emacs project
management. Ebib's more stateful, enclosed application model is not appropriate
because ordinary project files and external agent sessions remain authoritative.

## Decision

Valsi is an Emacs application for agent artifacts with optional terminal-agent
integration.

### Application hub

`M-x valsi` opens a project-level `*Valsi: PROJECT*` hub. The hub summarizes
recognized artifact families, warnings, active/recent artifacts, agent
instances, and relevant changed or stale files. It is the application's entry
buffer, analogous to Magit status.

The hub is not a generic file tree or project manager. It delegates:

- project roots and ordinary file selection to `project.el`;
- directories to `project-dired`;
- optional trees to a user-configured package such as Treemacs;
- Git operations to Magit/Git;
- builds and tests to `compilation-mode`;
- general window/tab management to Emacs.

### Dedicated artifact views

Grammar-specific source decoration, inspectors, dashboards, graph views,
verification, and node-diff review remain native Emacs buffers. Source files
stay ordinary editable Markdown and remain the source of truth.

### Agent terminals

Each agent instance is a real terminal-emulator buffer rooted at the canonical
Emacs project directory. Eat is the initial terminal implementation because it
is pure Elisp, available through Guix, and has rendered stock Pi successfully.

Pi is the default and fully tested CLI. Codex CLI, Claude Code, and custom
commands may occupy the same terminal role with capability-based integration.
The CLI owns:

- prompt editing and transcript rendering;
- tools, diffs, and shell interaction;
- authentication and subscription UX;
- models, context accounting, compaction, and sessions;
- its native keyboard commands and confirmations.

Valsi does not scrape terminal cells or duplicate those controls. It owns only
terminal lifecycle, project association, focus/layout conveniences, and
explicit artifact handoff.

### Artifact handoff

Selecting or inspecting an artifact does not silently alter an agent prompt.
An explicit command inserts or sends a stable artifact/task reference. Pi may
resolve richer context through the Valsi extension and AAP. Other CLIs may use a
future MCP/AAP face; without one they receive an ordinary path and identifier.

Normal agents retain their ordinary project capabilities. Valsi does not require
per-file attachment or task-manifest authorization before reads, edits, or
commands. Backend sandbox and approval behavior remains authoritative. An
explicit Valsi dry-run may still deny mutation.

### Refresh

The hub and dedicated views update from ordinary project changes:

- buffer edits reparse after an idle debounce;
- saves and agent/external writes refresh affected rows;
- filesystem notifications are hints, not the sole source of truth;
- opening the hub and `g` perform modification-time reconciliation;
- unsaved buffers are never overwritten and conflicts are shown explicitly.

### Window behavior

Valsi provides commands that compose existing buffers, not a mandatory
workspace manager. The hub, agent terminal, and artifact buffers may be used
independently. A convenience layout may display a large terminal beside a small
artifact index, but normal Emacs splitting and display rules remain valid.

### Multi-agent direction

Later multi-agent support manages lightweight agent instances rather than
becoming an agent runtime. The hub may list named terminal processes, backend,
task association, worktree, and coarse structured status. Writing agents should
normally use separate Git worktrees. Transcripts and credentials remain owned
by each CLI. Manager/worker orchestration requires structured backend support
and must not be simulated by scraping terminals.

## Consequences

Valsi stops carrying the maintenance burden of a second full agent frontend.
Users retain the normal UX and capabilities of their chosen agent, including
subscription login and project-wide file access. Artifact views remain native,
searchable, and composable with the terminal.

Eat becomes a runtime/package dependency for the built-in terminal integration.
Terminal buffers do not behave exactly like ordinary Emacs text buffers, and a
terminal-safe Valsi prefix must be tested. Capability differences between Pi,
Codex, and Claude must be shown honestly rather than hidden behind a false
common denominator.

The completed RPC work is not discarded wholesale. Protocol fixtures, the AAP
server, the Pi artifact extension, session projections, and deterministic
backend tests remain useful where a structured integration materially improves
artifact workflows. The RPC chat dashboard is demoted from the product's
primary UI and may be removed after reusable seams have been extracted.

## Migration

1. Establish `UI.md` and `UX.md` as the reviewed interaction specification.
2. Add the Magit-like project hub and automatic artifact refresh.
3. Package Eat and add project-scoped terminal agent instances.
4. Make Pi TUI the default agent surface; add capability-based Codex/Claude
   launchers.
5. Add explicit artifact-to-agent handoff.
6. Reuse or extract structured Pi/AAP seams needed for artifact callbacks.
7. Retire the native transcript/composer/login dashboard and attachment-derived
   policy after equivalent artifact workflows are available.
8. Add named agents and worktree isolation before higher-level orchestration.

Rollback does not require restoring a custom provider runtime. Users can always
run the selected CLI externally while retaining Valsi's artifact application.

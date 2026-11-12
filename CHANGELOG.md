# Changelog

All notable changes to Valsi are documented here.  The format follows
[Keep a Changelog](https://keepachangelog.com/) and the file is itself a
Valsi artifact: open it with `valsi-global-mode` on and the changelog
grammar activates.

## [Unreleased]

### Added

- A working-project overview (`valsi-projects`) with shared artifact attention,
  named agents, add/remove/filter actions, and explicit root persistence.
- Project switching restores each project's windows and selected buffer per
  frame. `P`/`w` and terminal-safe `C-c n P`/`C-c n w` provide consistent access.
- Terminal lifecycle updates and explicit task-status reporting, with stale
  instance rejection and project-level attention for input/review requests.
- Canonical project paths distinguish hubs, sidebars, command rails and agent
  terminals; source paths separate outlines, tables and plan review buffers.

- `make benchmark` measures project scans, hub reentry, sidebar display,
  dependency lint, source refresh, and editing latency.
- Direct Browse actions: `t` toggles, `A` selects the next actionable task,
  `G` jumps by id/name, `l` validates, `%` reports progress, and `o` filters
  by state. Toggles preserve Browse and respect preexisting read-only buffers.
- `make verify-meta`, run by `make check`: the `lisp/valsi.el` header is
  the single source of truth for version, URL and dependencies, and the
  Guix package, MELPA recipe, this changelog and the Pi extension are
  checked against it.
- `make info` builds the texinfo manual; CI builds it too.
- A CI job that installs markdown-mode and Eat so the optional paths run
  at least once.
- `examples/PLAN.md`, a sample plan opened by `make run` when the project
  has no PLAN.md of its own.
- `AGENTS.md` and this `CHANGELOG.md`, so the repository dogfoods its own
  instruction and changelog grammars.
- `valsi-detect-head-limit`: grammar detection under `valsi-global-mode`
  reads only the head of large buffers.
- Manual chapters for the changelog, decision and overview families, and
  links to the per-family reference documents under `doc/`.

### Changed

- Project refreshes yield between small batches of file operations. Hub opens
  return immediately, keep existing rows visible while refreshing, and share
  one scan with the sidebar. Edits cancel stale work; closing the last view
  cancels its timers. Failed scans preserve the last snapshot and allow retry.
- Parsing appends sibling nodes in constant time, keeping large flat plans
  and instruction lists responsive without changing the node model.
- Reopening a family dashboard preserves its sorting and selected row.
- Artifact synchronization parses once per text revision; typing updates
  semantic context after an idle pause, and fontification stays lazy.
- Project views reuse unchanged trees and structural diagnostics, refresh
  edited rows incrementally, and share one snapshot between subscribers.
- Sidebars show source context before project discovery. Returning to the hub
  preserves filters, folds, and the selected row.
- `Package-Requires` no longer declares Eat: it was always soft-required
  and the README already called it optional.  markdown-mode and Eat are
  documented as optional dependencies in the library header.
- `make test` loads every `test/*-test.el` instead of a hand-kept list.
- Historical working notes moved from `doc/` to `design/`.
- `valsi-plan--parse-current` split into per-line helpers.

### Fixed

- The graph reads each file once, shares its parsed tree among applicable
  grammar sources, excludes fenced examples and unrelated prose, and shows
  discovery, read, and source errors alongside successful edges (#102).
- Directory notifications queue bounded, ignore-aware watch discovery.
  Watches use hash lookups, preserve discovery in new empty folders, and
  report resource limits or backend failures instead of hiding them (#99).
- The retained RPC test client revokes released policies, starts with deny-all,
  removes temporary policy files and stderr buffers on stop/exit, and times
  out unanswered requests without retaining their callbacks (#101).
- The Pi artifact tool releases documents after each query, serializes
  concurrent access to one path, bounds and filters symbol output, enforces
  project-relative paths, and accepts documented uppercase configuration
  variables (#98).
- CI pins action revisions, checks Emacs 29.1, 30.2, and 31.1 plus an
  advisory snapshot job, and treats manual-build warnings as failures (#93).
- Named Pi terminals select separate, resumable sessions per project and name.
  Provider and model defaults come from Pi's configuration, and explicit
  session arguments override Valsi's selection (#96).
- The Guix Pi launcher retains host paths, sockets, and the working directory
  while supplying the ELF loader. Invalid home directories fail explicitly;
  existing loader-directory contents are preserved (#94).
- Guix source snapshots contain only tracked files, keeping local agent
  worktrees, private state, and build outputs out of the store (#91).
- Sidebar renders use cached path identities and buffer associations instead
  of filesystem probes for every Markdown file. Unrecognized unopened files
  are classified from a bounded head before any full artifact analysis (#97).
- ADR status editing is available for empty records, requires a lifecycle
  value and a superseding ADR where appropriate, and highlights lifecycle
  words only on the parsed status line (#105).
- Instruction sync handles large managed regions, uses the full narrowed
  source, protects open peer edits, and prevents nested imports on reverse
  sync. Text outside managed regions is preserved byte-for-byte (#100).
- Session-only project layouts are excluded from frameset/desktop persistence.
  Forgetting a project releases its saved layouts in every frame (#103).
- Nested plans resolve file references against the project root before their
  own directory, consistently across lint, follow, stale checks, and terminal
  handoff. Remote Flymake checks avoid filesystem probes; subtree completion
  preserves cancelled and unknown checkboxes and fenced examples (#104).
- Plan verification prompts for an editable command, runs asynchronously from
  the project root, and completes only the unchanged original task on success
  (#95).
- Standalone test, conformance, and benchmark runs load newer source instead
  of stale bytecode left by an earlier build (#92).
- Family dashboards refresh from their source artifacts, including unsaved
  edits, instead of parsing their own rendered tables. Outline navigation
  returns to the original artifact, and each dashboard keeps its own Enter
  binding when other views open.
- Hub navigation advances to the next row, Attention entries open their files,
  and overflow entries expand. File selection survives new Attention/Active
  rows. Edit and handoff work from any column on the selected row, and opening
  an artifact through the hub enables its grammar even without global mode.
- Nested task state evaluation visits each subtree once. Progress counts leaf
  tasks without counting their parents again; completed hierarchies no longer
  cause exponential work in lint, navigation, or task inspection.
- Dependency lint handles long chains and cycles without repeated recursive
  traversal or evaluation-depth errors that hid warnings in the hub.
- Narrowed buffers retain full-document coordinates and summaries.
- Sidebar context follows artifact switches, shows plan dependencies, and
  dispatches the existing occur command. Closed hubs detach observation hooks.
- The `URL:` header and the Guix package home page pointed at a repository
  slug that no longer exists.
- The Pi extension's `package.json` still carried the removed policy-gate
  name, and the Makefile, CI and `package.json` disagreed on the test
  runner.  The tests are `node:test` files; everything now runs them with
  `node --test` (Bun still works via `make test-extension NODE=bun`), and
  `make guix-test-extension` uses Guix's node package, since Guix has no
  Bun.

## [1.0.0] - 2026-07-04

### Added

- Plan/tasks grammar with five dialects, structure editing, lint,
  cross-artifact traces, and dispatch of a task to a terminal agent.
- Instruction, prompt-file, memory, changelog, decision and overview
  grammars.
- The cross-artifact graph.
- The project hub (`M-x valsi`) and Eat-backed agent terminals.
- Agent Artifact Protocol v0 specification, in-process and stdio servers,
  and a conformance suite.
- Guix package and MELPA recipe.

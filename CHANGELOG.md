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

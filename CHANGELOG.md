# Changelog

All notable changes to Valsi are documented here.  The format follows
[Keep a Changelog](https://keepachangelog.com/) and the file is itself a
Valsi artifact: open it with `valsi-global-mode` on and the changelog
grammar activates.

## [Unreleased]

### Added

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

- `Package-Requires` no longer declares Eat: it was always soft-required
  and the README already called it optional.  markdown-mode and Eat are
  documented as optional dependencies in the library header.
- `make test` loads every `test/*-test.el` instead of a hand-kept list.
- Historical working notes moved from `doc/` to `design/`.
- `valsi-plan--parse-current` split into per-line helpers.

### Fixed

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

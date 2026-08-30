# Agent instructions

Guidance for coding agents working in this repository.  This file is an
instruction artifact; Valsi's instruction grammar activates on it.

@./doc/architecture.md

## Build and test

- Run `make check` before every commit.  It byte-compiles with warnings
  as errors, runs Checkdoc, checks packaging metadata, and runs ERT.
- Without a local Emacs use `make guix-check`.
- NEVER commit `.elc` files or `doc/valsi.info`; they are build outputs.
- The Pi extension has its own suite: `make test-extension` (`node --test`).

## Packaging facts live in one place

- The header of `lisp/valsi.el` is the source of truth for the version,
  the repository URL and the hard dependency set.
- Bump the version there, add a `## [x.y.z]` section to `CHANGELOG.md`,
  and update the version in `valsi.scm`.  `make verify-meta` fails until
  all three agree.
- Do not restate dependencies in prose; point at the header instead.

## Invariants

- YOU MUST keep every file byte-identical when Valsi is disabled.
  Grammars annotate, they never rewrite unrecognized text.
- Grammars are descriptive: a partially matching file resolves less
  detail, it is never rejected.  See `doc/adr/0001-descriptive-grammar.md`.
- NEVER add a tree-sitter or external parser dependency; recognizers stay
  pure elisp (`doc/adr/0002-pure-elisp-parser.md`).
- Agent execution stays outside the AAP protocol surface.

## Style

- Every file uses `lexical-binding: t`, a `valsi-` prefix, and a
  docstring on every public command.
- Match the surrounding naming and comment density.
- New behavior gets an ERT test under `test/`; every `test/*-test.el` is
  loaded automatically by `make test`.
- Record architectural decisions as ADRs under `doc/adr/`.

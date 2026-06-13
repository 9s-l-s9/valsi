# Agent instructions

Top-level guidance for agents working in this repository.

@./doc/architecture.md

## Build & test

- Run `make check` before every commit.
- IMPORTANT: never commit `.elc` files; they are build artifacts.
- YOU MUST keep every file byte-identical when Valsi is disabled.

## Style

- Match the surrounding code's naming and comment density.
- NEVER introduce a tree-sitter dependency — recognizers stay pure elisp.
- See [[grammars-are-user-definable]] for the adaptability thesis.

### Elisp specifics

- Use `lexical-binding: t` in every file.
- ALWAYS add a docstring to public commands.

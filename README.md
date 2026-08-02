# Valsi

Valsi (Lojban for "word") is an Emacs harness for the Markdown
artifacts that accumulate around coding agents: PLAN.md, AGENTS.md,
SKILL.md, MEMORY.md, CHANGELOG.md, and their relatives.

Peter Naur argued in "Programming as Theory Building" that the real
program lives in the programmer's head and the files are lossy carriers
of it.  Working with agents makes this acute: the shared theory has to
live in artifacts that both sides can read and write.  Valsi treats
those artifacts as the workspace:

    Artifact = Data + Grammar + View + Actions + Keymap

Grammars are descriptive, not normative: sets of recognizers over plain
Markdown, closer to a linguist's grammar than to a validator's schema.
A file that only partially matches is not invalid; it resolves less
detail and gets the subset of views and commands its structure
supports.  Agents read and write artifacts through the same grammar,
and their edits are checked back against it.  Files stay ordinary
Markdown on disk; close Valsi and they are still just files.

Grammars are plugins and can be defined or redefined while Emacs runs,
so a bespoke, per-project artifact type is a normal thing to add.

## Requirements

Emacs 29.1 or later and markdown-mode.  The optional terminal-agent
integration additionally uses Eat and an agent CLI (Pi is the tested
default; Codex CLI and Claude Code also work).  Guix is convenient but
not required.

## Installation

With Guix (the repository ships `valsi.scm`):

    guix build -f valsi.scm                   # build + byte-compile
    guix shell -D -f valsi.scm -- make check  # dev shell + test suite

From MELPA (recipe under `recipes/valsi`):

    M-x package-install RET valsi RET

Manually:

    (add-to-list 'load-path "/path/to/valsi/lisp")
    (require 'valsi)
    (valsi-global-mode 1)

## Usage

`valsi-global-mode` activates the matching grammar when you visit a
recognized artifact:

| File                                        | Grammar                 |
|---------------------------------------------|-------------------------|
| `PLAN.md`, `specs/*/tasks.md`               | plan/tasks (5 dialects) |
| `AGENTS.md`, `CLAUDE.md`, `.cursor/rules/*` | instruction             |
| `SKILL.md`, subagents, commands             | prompt-file             |
| `MEMORY.md`, `memory/*.md`                  | memory                  |
| `CHANGELOG.md`                              | changelog               |
| `doc/adr/*.md`                              | decision (ADR/MADR)     |
| `README.md`, `ARCHITECTURE.md`              | overview                |

Commands live on the `C-c n` prefix and dispatch to the active
grammar; `C-c n m` opens the menu.  The most used ones:

    C-c n n / p     next / previous element
    C-c n t         toggle / cycle at point
    C-c n g         goto by id or name
    C-c n l         lint / validate
    C-c n a         next actionable task
    C-c n RET       follow reference
    C-c n d         family dashboard
    C-c n G         cross-artifact graph

`M-x valsi` opens the project hub: a Magit-like summary of the
project's plans, instructions, skills, memories, decisions, and agent
terminals, with single-key navigation (`n`/`p`, `TAB`, `RET`, `g`,
`?`).  `M-x valsi-agent` runs the configured agent CLI in an Eat
terminal; the CLI keeps its own prompt, tools, and credentials, and
Valsi hands it artifact context rather than wrapping it.

To try everything in a scratch Emacs:

    make run      # guix shell + emacs -Q -l valsi-demo.el
    make check    # byte-compile (warnings as errors) + Checkdoc + ERT

## Documentation

The reference manual is `doc/valsi.texi` (`makeinfo doc/valsi.texi`).
`doc/architecture.md` describes the client/server split over the Agent
Artifact Protocol; the protocol itself is specified in
`doc/aap-spec.md` with a conformance suite under `test/conformance/`.
Design decisions are recorded in `doc/adr/`.

## License

GPL-3.0-or-later; see COPYING.

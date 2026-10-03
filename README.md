# valsi

*Lojban · [/ˈvalsi/](https://www.lojban.org/publications/reference_grammar/chapter3.html) · [word](https://vlasisku.lojban.org/valsi)*

An Emacs workspace for the Markdown you share with coding agents. Navigate
plans, review changes, and give your own document conventions dedicated tools.

![Emacs Lisp](https://img.shields.io/badge/core-Emacs_Lisp-555555?style=flat-square)
![Markdown](https://img.shields.io/badge/artifacts-Markdown-555555?style=flat-square)
[![GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-555555?style=flat-square)](COPYING)

## What you can do

- **Work across project knowledge.** A Magit-like project hub, family dashboards
  and a cross-artifact graph bring plans, instructions, skills and decisions
  together. Navigate elements, follow references and find actionable tasks.
- **Give your conventions their own tools.** Define or redefine a grammar while
  Emacs runs. Recognizers attach structure, views, actions and keymaps to the
  document types your project actually uses.
- **Keep context close to the work.** Run an agent CLI in an Emacs terminal,
  hand it explicit artifact context and use structured review views for edits.
  The CLI owns its tools and sessions; Valsi owns the artifact workspace.

## How it fits together

```text
Markdown + grammar -> structured nodes -> views, actions, keymaps
```

Grammars describe the structure they recognize. A partially matching document
gets the functions its recognized structure supports, and unrecognized text
remains intact. You can adopt Valsi incrementally and extend it as your project
conventions develop.

The parser, grammar registry and node model sit behind the Agent Artifact
Protocol (AAP) boundary. The current implementation runs inside Emacs; the Emacs
client turns that model into editable buffers, dashboards and review views.
See the [architecture](doc/architecture.md) for the boundaries and extension model.

Valsi is for developers who treat the plans and decisions around their code as
part of the engineering work, and enjoy building an editor environment around
that knowledge.

## Requirements

Emacs 29.1 or later, as declared in the `Package-Requires` header of
`lisp/valsi.el` (the single source of truth for version, URL, and
dependencies).  markdown-mode and Eat are optional; the terminal-agent
integration uses Eat plus an agent CLI (Pi is the tested default; Codex
CLI and Claude Code also work).  Guix is convenient but not required.

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

`M-x valsi-projects` opens the working-project overview. Use `+` to add a
project from Emacs's known projects (or choose another directory), `RET` to
resume it, `c` for its hub, `a` for its primary agent, and `N` for a new named
agent. Each project shows artifact attention and named terminals. `TAB` folds,
`/` filters, `g` refreshes, and `-` removes a project from the list without
closing its buffers or deleting files. Stop live agents explicitly before
removing their project.

`P` returns to Projects and `w` switches projects from Valsi Browse views.
In editable artifacts and terminals use `C-c n P` and `C-c n w`; these actions
also appear in `M-n`. Switching restores each project's windows and selection
in the current frame, leaving unsaved text and running terminals intact.
`q` in Projects restores the layout from which you opened it. Outside a
project, `M-x valsi` opens Projects; `C-u M-x valsi` does so from anywhere.

Projects opened in this session appear automatically. Explicit `+` additions
are remembered in `valsi-project-file`; set it to nil for session-only use.
Only roots persist: window layouts and running processes last for this Emacs
session. Unavailable roots stay listed, and remote roots are opened explicitly
instead of connecting during background overview refresh.

Agent rows report `running` or `stopped` from the process. Explicit task reports
can show `working`, `needs input`, `ready to review`, or `idle`; the middle two
also contribute to project attention. Use `M-x valsi-terminal-agent-set-status`
to record a status manually. Backend adapters can call
`valsi-terminal-agent-report-status` with the current instance. Automatic
backend task reporting is not yet connected; Valsi does not infer task state
from terminal output. The plan and boundaries are in
[design/multi-project.md](design/multi-project.md).

In an artifact's Browse state, use `n`/`p` to move, `t` to cycle its
state, `A` for the next actionable task, and `G` to jump by id/name.
`i` enters text editing; `ESC` returns to Browse. `c` returns to the
hub with its filter, folds, and selection preserved. `a` opens the
agent, and `@` inserts the current artifact reference into its prompt
for review. `SPC` shows the remaining commands.

The hub and sidebar appear immediately; project counts and diagnostics refresh
in small batches while Emacs remains available for input. Existing rows stay
visible with a refreshing indicator until the new snapshot is ready. `g`
requests a fresh scan. For repeatable latency measurements, including initial
display and the longest processing turn, run `make benchmark`.

To try everything in a scratch Emacs:

    make run      # guix shell + emacs -Q -l valsi-demo.el
    make check    # byte-compile (warnings as errors) + Checkdoc + verify-meta + ERT

`make run` opens the project's PLAN.md, or `examples/PLAN.md` when the
project has none.

## Documentation

The reference manual is `doc/valsi.texi` (`make info` builds
`doc/valsi.info`).  Per-family references: `doc/plan-editing.md`,
`doc/plan-cross-artifact.md`, `doc/plan-agent.md` (plan),
`doc/instruction.md` (instruction), and `doc/promptfile.md`
(prompt-file).  `doc/architecture.md` describes the client/server split
over the Agent Artifact Protocol; the protocol itself is specified in
`doc/aap-spec.md` with a conformance suite under `test/conformance/`.
Design decisions are recorded in `doc/adr/`; design notes and
historical working notes are under `design/`.  `CHANGELOG.md` records
releases (Keep a Changelog) and `AGENTS.md` holds the working rules for
contributors and agents.

## License

GPL-3.0-or-later; see COPYING.

# Valsi

> *valsi* — Lojban for “word”.

**How to achieve mastery in managing Agents?**

Peter Naur argued in *Programming as Theory Building* that the real program lives in the programmer's head, and the files are lossy carriers of it. Letting others, humans and agents, share that program, makes it increasingly important to work with additional artifacts.

Today this is done by writing random markdown files, PLAN.md, CLAUDE.md, SKILL.md, SPECS.md, MEMORY.md, ...

Valsi is an agent harness where the artifacts are the core workspace.

```
Artifact = Data + Grammar + View + Actions + Keymap
```

The grammar is descriptive, not normative: a set of recognizers over plain markdown, like a linguist's grammar rather than a validator's schema. A file that only partially matches isn't invalid — it just resolves less detail, and gets the subset of views and commands its structure supports. Agents read and write artifacts through the same grammar: it tells them how an artifact is shaped, and their edits are checked back against it.

Valsi can adapt itself to your specific project and workflow, by providing optimized views and commands to interact with those artifacts.

## Three commitments

**Structure over transcripts.** Collaboration with an agent should happen through shared, structured artifacts — not by scrolling a chat log to reconstruct what was decided.

**Control over delegation.** Valsi is for people who master their tools. Agent
permissions remain visible and configurable in the selected CLI, every
artifact view is inspectable, and everything is yours to rebind and reshape.
If you're content with whatever `plan.md` falls out of your harness, this
isn't for you.

**Files over formats.** Artifacts stay plain markdown on disk — diffable, git-friendly, readable by any editor, any harness, any model. Valsi is the lens, not a lock-in. Close it and your files are still just files.

## Extensible while running

New workflow, new artifact type: define its grammar, view, and commands live, evaluate, use. No rebuild, no plugin marketplace. The harness grows in whatever direction your work does — which is why it's built on Emacs, the one environment that's been a live, self-modifying system for forty years. 

## Method

Grammars are derived, not invented. For each common artifact type (AGENTS.md, PLAN.md, SKILL.md, ...):

1. Collect real examples in the wild, starting with those officially promoted by Anthropic and similar companies.
2. Find the recurring patterns and derive the grammar from them.
3. Work out which commands actually help when interacting with such an artifact.
4. Build a dedicated Emacs mode on top.

## Try it

The client lives in `lisp/`. Launch a demo Emacs with all four grammars loaded:

```sh
make run          # guix shell + emacs -Q -l valsi-demo.el
make check        # byte-compile (warnings→errors) + Checkdoc + ERT suite
```

Or, from any Emacs:

```elisp
(add-to-list 'load-path "/path/to/valsi/lisp")
(require 'valsi)
(valsi-global-mode 1)     ; auto-activates the right grammar per file
```

Open any recognized artifact and the matching grammar activates automatically:

| File | Grammar | Tier |
|---|---|---|
| `PLAN.md`, `specs/*/tasks.md` | plan / tasks (5 dialects) | emergent |
| `AGENTS.md`, `CLAUDE.md`, `.cursor/rules/*` | instruction | emergent |
| `SKILL.md`, subagents, commands | prompt-file | emergent |
| `MEMORY.md`, `memory/*.md` | memory | emergent |
| `CHANGELOG.md` | changelog (Keep a Changelog) | standardized |
| `doc/adr/*.md` | decision (ADR/MADR) | standardized |
| `README.md`, `ARCHITECTURE.md` | overview | converging |

Every command hangs off the `C-c n` prefix
and dispatches to the active grammar (`C-c n m` opens the transient menu):

| Key | Action |
|---|---|
| `C-c n n` / `p` | next / previous element |
| `C-c n t` | toggle / cycle at point |
| `C-c n g` | goto by id / name |
| `C-c n i` | info at point |
| `C-c n %` | progress |
| `C-c n a` | next actionable task |
| `C-c n l` | lint / validate |
| `C-c n RET` | follow reference |
| `C-c n d` | family dashboard |
| `C-c n G` | cross-artifact graph |
| `C-c n m` | transient menu |

Each family also has a dedicated tabulated view: a cross-file **plan agenda**,
an **instruction scope-map**, a **prompt-file frontmatter table**, a **memory
index**, and the project-wide **cross-artifact graph**.

## The Valsi application and agent terminals

ADR 0006 reframes Valsi as a Magit-like Emacs application for agent artifacts.
`M-x valsi` opens a project hub that summarizes recognized plans, instructions,
skills, memories, decisions, warnings, recent artifacts, and associated agent
instances. Dedicated family dashboards, inspectors, graph views, verification,
and node-diff review remain native Emacs buffers. Source files remain ordinary
editable Markdown.

The hub is not a file tree or a replacement for Emacs project management:

- `project.el` owns project roots and file selection;
- `project-dired` provides a directory view;
- Magit/Git owns version control;
- `compilation-mode` owns builds and verification;
- an optional configured package may provide a full project tree.

The hub updates after buffer edits, saves, agent/external writes, and filesystem
notifications. Opening it and pressing `g` reconcile modification times.
Unsaved buffers are never overwritten; disk conflicts are reported.

Agent conversation runs in a real Eat terminal buffer, for example
`*Valsi Agent: valsi/primary*`. Pi is the default Guix-pinned backend; Codex CLI,
Claude Code, and custom commands may use the same terminal role. The CLI owns
its prompt, transcript, tools, diffs, authentication, models, context display,
confirmations, and sessions. Valsi does not parse terminal cells or reproduce
those controls.

Normal agent capability is preserved: the CLI starts at the canonical project
root and may read, search, edit, and run commands according to its own
sandbox/approval settings. Artifact selection is semantic context, not a
per-file permission system. An explicit command can insert a path/task
reference into the terminal prompt without submitting it. Pi may resolve richer
artifact context through Valsi's extension and AAP; other CLIs can use a future
MCP/AAP face or fall back to the plain reference.

Useful entry points are planned as:

| Command | Action |
|---|---|
| `M-x valsi` | open the project artifact hub |
| `M-x valsi-agent` | open/focus the project's configured agent terminal |
| `M-x valsi-artifacts` | open/focus the compact artifact index |
| `M-x valsi-agent-with-artifacts` | compose terminal plus artifact index |
| `C-c n m` | show the context-sensitive Valsi command menu |

The exact buffer anatomy, layouts, focus behavior, and proposed shortcuts are
specified in [`UI.md`](UI.md) and [`UX.md`](UX.md).

Pi remains the tested subscription path. Authentication happens in Pi's own
terminal UI, so Pi exclusively stores and refreshes credentials. OpenAI Codex
through a ChatGPT subscription is the intended no-API-key path. Pi's Claude
Pro/Max path may draw from Anthropic extra usage billed per token rather than
included plan limits.

Later multi-agent support adds named terminal instances to the hub. Valsi tracks
only lightweight identity, backend, task association, process, worktree, and
structured status. Writing agents should normally use separate Git worktrees;
credentials and transcripts remain owned by each CLI. Valsi coordinates through
artifacts and worktrees rather than becoming another agent runtime. The exact
data model and collision rules are in
[`doc/multi-agent.md`](doc/multi-agent.md).

The optional Pi extension is deliberately narrow: it contributes the
read-only `valsi_artifact` AAP tool and nothing else. If the extension is absent,
Pi still runs normally and artifact handoff falls back to plain path/task
references.

## Installation

**Guix** (reproducible; the repo ships `valsi.scm`):

```sh
guix build -f valsi.scm                   # build + byte-compile the package
guix shell -D -f valsi.scm -- make check  # dev shell + full test suite
guix shell -f valsi.scm -- pi --version   # pinned harness runtime
```

The Guix package propagates Pi 0.80.6, Eat, and Valsi's optional AAP extension.
For MELPA/manual installation, install a compatible agent CLI and Eat. Set
`valsi-agent-pi-extension-file` only when the extension is not installed beside
Valsi and is not available from the source tree.

**MELPA** (recipe under `recipes/valsi`):

```elisp
M-x package-install RET valsi RET
```

**Manual** (any Emacs; requires `markdown-mode`):

```elisp
(add-to-list 'load-path "/path/to/valsi/lisp")
(require 'valsi)
(valsi-global-mode 1)
```

The Emacs floor is 29.1 (CI/dev on 30.2). The reference manual is
[`doc/valsi.texi`](doc/valsi.texi) (`makeinfo doc/valsi.texi` → Info); the v1.0
acceptance matrix is [`doc/qa-matrix.md`](doc/qa-matrix.md).

## Architecture

A client/server split over the Agent Artifact Protocol (AAP). The model —
node tree (`valsi-node`), pure-elisp recognizers (`valsi-parse`), and the
hot-reloadable grammar-plugin registry (`valsi-registry`) — is editor-agnostic;
the Emacs client (`valsi.el` + `valsi-view`) renders it. Grammars
(`valsi-plan`, `valsi-instruction`, `valsi-promptfile`, `valsi-memory`) are
plugins that declare recognizers → node types → advertised capabilities. See
[`doc/architecture.md`](doc/architecture.md) and [`PLAN.md`](PLAN.md).

---

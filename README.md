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

**Control over delegation.** Valsi is for people who master their tools. Every agent action is scoped, every view is inspectable, everything is yours to rebind and reshape. If you're content with whatever `plan.md` falls out of your harness, this isn't for you.

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
make check        # byte-compile (warnings→errors) + ERT suite
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

## Architecture

A client/server split over the Agent Artifact Protocol (AAP). The model —
node tree (`valsi-node`), pure-elisp recognizers (`valsi-parse`), and the
hot-reloadable grammar-plugin registry (`valsi-registry`) — is editor-agnostic;
the Emacs client (`valsi.el` + `valsi-view`) renders it. Grammars
(`valsi-plan`, `valsi-instruction`, `valsi-promptfile`, `valsi-memory`) are
plugins that declare recognizers → node types → advertised capabilities. See
[`doc/architecture.md`](doc/architecture.md) and [`PLAN.md`](PLAN.md).

---

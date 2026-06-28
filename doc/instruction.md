# Instruction files — scopes, imports, sync (the degradation test)

Instruction files — `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, Cursor
`.cursor/rules/*.mdc`, GitHub Copilot `.github/instructions/*.instructions.md` —
are the **biggest install base and the weakest inherent structure** in the whole
artifact set. Most of the file is free prose. That makes this genre Valsi's
sharpest degradation test: it must add real value *without requiring* any
structure, because the file is, and must stay, ordinary markdown a plain editor
reads unchanged. The derived grammar is in
[`research/04-instruction-grammar.md`](../research/04-instruction-grammar.md).

## Two scope axes

An instruction file selects *when its rules apply* by one of two mechanisms, and
Valsi recognizes both:

- **Location scope** (`AGENTS.md`/`CLAUDE.md`/`GEMINI.md`): the file's directory
  plus its `##` heading tree. Rules apply to work under that directory; deeper
  files refine shallower ones (nearest wins).
- **Predicate scope** (Cursor/Copilot): YAML frontmatter attaches the *whole
  file* to a set of globs — `globs:` (Cursor) or `applyTo:` (Copilot) — with
  `description:` as the trigger and `alwaysApply: true` making it global.

```yaml
---
description: Enforce API conventions
globs:
  - "src/api/**/*.ts"
alwaysApply: false
---
```

`M-x valsi-instruction-effective-at-point` (also `info`/`effective` on the `C-c n`
menu) reports the nearest-wins **heading path** at point, and — when the file is
glob-scoped — the glob predicate the whole file applies to. This is the genre's
headline query: *"which instructions are in force right here?"*

## Imports and links

- **`@imports`** (`@./AGENTS.md`, `@~/.claude/x.md`, `@docs/architecture.md`)
  pull other files into context. They form a directed graph.
  `M-x valsi-instruction-import-graph` (`graph`) renders the transitive import
  tree rooted at the current file, marking `[missing]` targets and guarding
  cycles. `M-x valsi-instruction-follow` (`follow`) jumps to the `@import` or
  `[[link]]` at point.
- **`[[links]]`** are soft cross-references (to a memory, a doc, another
  instruction). They are recognized as node props and navigable — they do *not*
  pull content the way `@imports` do.

## Lint

`M-x valsi-instruction-lint` reports two health issues over the resolved tree:

- **Dangling `@import`** — a target that does not resolve to a readable file.
- **Unscoped frontmatter** — a `.mdc`/`.instructions.md` file whose frontmatter
  declares no `globs`/`applyTo` and is not `alwaysApply: true`, so no tool can
  target it.

The pure core (`valsi-instruction--lint-collect`) is filesystem-free over the
tree; the on-disk import check is layered on when a directory is known.

## Sync — one source, many targets

Many projects must keep `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` saying the same
thing for different tools. `M-x valsi-instruction-sync` treats **the current file
as the canonical source** and mirrors it into a **managed region** of each chosen
peer:

```
<!-- valsi:sync:begin (managed by valsi-instruction; do not edit inside) -->
…canonical content…
<!-- valsi:sync:end -->
```

Only the managed region is rewritten — each target's own tool-specific content
(its hand-written `@import` block, say) is preserved verbatim outside the fences.
Sync is **surgical and idempotent**: re-running with an unchanged source is a
byte-for-byte fixed point, and it prompts before writing each file. This is the
"control over delegation" invariant applied to file generation — Valsi never
silently clobbers a target. The region computation
(`valsi-instruction--sync-region`) is a pure string function, tested without
touching the filesystem.

## Scaffold

`M-x valsi-instruction-scaffold` writes a starter instruction file (default
`AGENTS.md`) with the conventional `Setup` / `Build & test` / `Conventions`
scaffold and an emphasis marker, ready to fill in.

## Capability ladder (this genre)

| Rung | Given | You get |
|---|---|---|
| 0–1 | any markdown | open, plain edit, outline, narrow-to-section |
| 2 | emphasis markers | highlighted strong rules |
| 3 | heading scopes | effective-instructions-at-point (nearest-wins) |
| 4 | frontmatter globs | predicate scope: which rules apply to a file |
| 5 | imports/links | import graph, follow, dangling-import lint |
| 6 | a multi-file set | one-source→many-targets **sync**, **scaffold** |

Nothing above rung 0 is required: a bare prose `AGENTS.md` still opens, outlines,
and edits as plain markdown. Each rung is a bonus the structure earned.

# Prompt files — the strict-frontmatter genre

Prompt files — `SKILL.md`, subagent definitions (`.claude/agents/*.md`), and
slash commands (`.claude/commands/*.md`) — are the mirror image of the
[instruction genre](instruction.md). Instruction files are the weakest-structure
degradation test; prompt files are **the one place a real, near-mandatory
schema lives at the top of the file**. A `SKILL.md` without a `name` and
`description` does not load; a subagent without a `description` never gets
delegated to. So here Valsi's value is *validation and completion of a known
vocabulary* — the opposite end of the ladder. The derived grammar is in
[`research/05-promptfile-grammar.md`](../research/05-promptfile-grammar.md).

A prompt file is two documents stacked: a **strict, typed frontmatter header**
and a **free-prose body** (the actual prompt).

## The eager / lazy split

The organizing insight of the SKILL.md design — *progressive disclosure* — is
first-class in Valsi's node model:

- **Eager** — the frontmatter (above all `name` + `description`) is in the
  agent's context **always**. The model reads the description to decide whether
  this skill/subagent/command is relevant *right now*. It must stay small.
- **Lazy** — the body is pulled into context **only when the trigger fires**.

Every node carries a `:disclosure` property (`eager` on the frontmatter, `lazy`
on body sections). This is why *description-as-trigger* is the headline lint: a
weak eager trigger means the lazy body never loads.

## Three per-type vocabularies

One grammar, three vocabularies, chosen by a pure discriminator over the file's
location and frontmatter:

| Type | Location | Required | Known optional |
|---|---|---|---|
| **skill** | `SKILL.md` | `name`, `description` | `license`, `allowed-tools`, `version`, `metadata` |
| **subagent** | `.claude/agents/*.md`, `agents/**` | `name`, `description` | `tools`, `model`, `color` |
| **command** | `.claude/commands/*.md`, `commands/**` | *(none)* | `description`, `argument-hint`, `allowed-tools`, `model`, `disable-model-invocation` |

`M-x valsi-info` (the `info` action) echoes the detected type and fields.

## Validate

`M-x valsi-lint` / `valsi-promptfile-validate` checks the frontmatter against its
type's vocabulary:

- **Missing required key** — a skill/subagent without `name` or `description`.
- **Unknown key** — a key outside the type's known set, reported as a
  *warning* (the vocabulary is open in spirit; a new key is a nudge, not a
  failure).
- **Weak description** — a `description` too short to be a real trigger, over
  the length cap, or a bare restatement of `name`. This is the highest-value
  check: a weak eager trigger means the lazy body is dead weight.

A command has no required keys, so a bare prompt-template file validates clean.

## Complete a key

`valsi-promptfile-complete-key` (the `complete` action) offers the known keys for
this file's type that are **not yet present**, and inserts the chosen one into
the frontmatter ready to fill in — schema-aware completion without a schema
language.

## Test-fire — "would this prompt match?"

`M-x valsi-promptfile-test-fire` prompts for a candidate task/query and scores it
against the `description` by keyword overlap, reporting whether the prompt would
*likely trigger*, *partially match*, or *not trigger*. It is a design aid — not
the real matcher — for tuning a description until it fires on the right work.

## Argument placeholders

Command bodies interpolate user input via `$ARGUMENTS`, `$1`, `$2`, …. Valsi
recognizes these (highlighted, and collected on the root node's `:args`) so a
command's arity is visible at a glance.

## Scaffold a skill directory

A skill is not one file but a directory. `M-x valsi-promptfile-scaffold` creates
`SKILL.md` (with a `name`/`description` frontmatter template) alongside the
conventional `scripts/`, `references/`, and `assets/` siblings, then opens the
`SKILL.md` for editing.

## Capability ladder (this genre)

| Rung | Given | You get |
|---|---|---|
| 0–1 | any markdown | open, plain edit, outline, narrow-to-section |
| 2 | a frontmatter block | field table (`info` / `dashboard`) |
| 3 | a typed vocabulary | **validate** (required + unknown-key), **complete** a key |
| 4 | a `description` | description-as-trigger lint, **test-fire** |
| 5 | a skill family | **scaffold** a skill dir (scripts/references/assets) |

Nothing above rung 0 is required: a bare prose command still opens and edits as
plain markdown.

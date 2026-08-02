# 1. Descriptive grammars over plain markdown, never normative

Date: 2026-07-13

## Status

Accepted. The foundational decision the whole project rests on. ADR 0004
(artifact protocol) builds on this without changing it — 0004 revised the
*delivery* ("in-process minor-mode" → "reference client/server over AAP"); the
*descriptive-grammar* decision here still holds unchanged.

## Context

Valsi's thesis (README) is that a project's shared "theory" — in Peter Naur's
sense — must live in **structured artifacts**, not chat transcripts. The
artifacts in question (plan/tasks files, AGENTS.md/CLAUDE.md, SKILL.md, memory
files, ADRs, changelogs) are already **ordinary markdown on disk**, authored by
many tools and hands, in dialects that diverge and are *months* old as
conventions. Almost none of them is a settled standard (a nascent field).

The core design question: what is a Valsi "grammar"? Two stances were possible.

- **Normative / schema-first** — define a canonical structure, validate files
  against it, reject or rewrite what doesn't conform (the XML-schema / linter-gate
  posture). This is how most structured-document tooling works.
- **Descriptive / recognizer-first** — a grammar is a set of **tolerant
  recognizers** over plain markdown that *annotate* structure where they find it
  and stay silent where they don't. A parse never fails and never rewrites.

A normative stance is fatal here for three reasons: (1) the corpus is diverging,
so any canonical schema is wrong for someone the day it ships; (2) the files must
stay portable — a plain editor, `grep`, and `git diff` must keep working, and a
non-Valsi user must never receive a file Valsi "fixed"; (3) capability must be able
to **degrade** rather than break when structure is partial or unfamiliar.

## Decision

**Valsi grammars are descriptive, never normative.**

1. **A grammar is a set of tolerant recognizers over plain markdown.** Each
   recognizer classifies a line or block into a typed node with provenance and a
   confidence (`exact | loose`); the union always runs; unrecognized text is
   simply un-annotated, never an error. (`valsi-parse`, `valsi-node`.)
2. **Parsing never fails and never rewrites.** *Invariant (test-enforced):*
   `parse → serialize` is the **identity** on every corpus file. Disabling Valsi
   leaves the buffer and the on-disk bytes identical (the minor-mode /
   files-over-formats commitment).
3. **Capability follows structure — the six-rung degradation ladder**
   (`design/plan-grammar.md` §4). Each command declares the rung it needs and is
   gated or falls back below it. Under AAP (ADR 0004) this ladder is realized as
   **per-document capability advertisement**: the server reports which requests a
   document supports given the structure its grammar actually resolved.
4. **Grammars are yours to define.** A grammar is *just* a recognizer set —
   **who authors one is open**. Bespoke, per-project grammars are first-class;
   the grammars Valsi bundles are opinionated defaults, not the point.
   Corpus-derivation is only how Valsi **bootstraps the
   grammars it ships** — it is *not* a property of grammars, nor a requirement,
   nor load-bearing.
5. **Evidence over false standards.** Every *bundled* grammar is derived from a
   real corpus and carries an **evidence tier** (`standardized` / `converging` /
   `emergent`), recorded in its research doc and surfaced in docs/lint text.
   Valsi never dresses "a few repos do this" up as a standard. (User- or
   project-defined grammars carry no such pedigree obligation.)

## Consequences

**Positive**

- Files stay portable and diffable; Valsi is safe to enable on a repo shared with
  non-Valsi users. Nothing Valsi-only lives on disk that the file's own text can't
  reconstruct.
- Partial or unfamiliar structure degrades gracefully instead of breaking — a
  direct fit for a diverging, months-old ecosystem.
- The adaptability thesis (ADR 0004) is possible *because* grammars are cheap
  recognizer sets anyone can define, not schemas to be ratified.

**Negative / costs**

- Recognizers are tolerant, so ambiguity is real: the same text may be loosely
  classified more than one way. Handled with the `exact | loose` confidence field
  and per-node dialect exceptions, not by tightening into a schema.
- No validation gate means Valsi cannot *guarantee* a file is "correct" — by
  design. Where users want checking, it is offered as **advisory lint** with
  mechanical fixes (opt-in), never as a parse-time rejection.

**Neutral**

- "Descriptive" governs *recognition*. Writing back through the grammar
  (structure-editing, agent node-diffs) is still allowed and safe **because** the
  round-trip identity invariant bounds it: an edit changes exactly the nodes it
  claims and nothing else.

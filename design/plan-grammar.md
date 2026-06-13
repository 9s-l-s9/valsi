# Valsi plan/tasks grammar — v0.1 specification

Consolidated from `research/02-plan-tasks-grammar.md` (corpus-derived, rounds
1–2). This is the implementable spec: data model, recognizers, dialect
profiles. Descriptive throughout — recognizers annotate, they never reject.

## 1. Data model (what a parse produces)

The parse of a plan/tasks file is a tree of typed nodes overlaid on the
buffer; every node keeps its buffer region (start/end markers), so views and
edits round-trip losslessly. Unrecognized text stays in the tree as `prose`.

```
Plan
├─ frontmatter?          ; YAML alist (R11)
├─ preamble?             ; prose + meta-fields before first group
└─ Group*                ; from heading, parent-task, or <tasks> container
   ├─ meta*              ; purpose/goal/checkpoint/files/spec-ref fields
   ├─ Task*
   │  ├─ state           ; open | done | in-progress | cancelled | unknown(char)
   │  ├─ id?             ; dialect-shaped string, parsed into sort key
   │  ├─ tags            ; list: parallel(P) | story(USn) | label(word)
   │  ├─ description     ; rich text: prose + path-refs + inline-deps
   │  ├─ deps            ; resolved refs (from inline "(depends on …)")
   │  ├─ traces          ; requirement-ids, story, path-refs (R6)
   │  ├─ files?          ; manifest: (verb . path)* (R9)
   │  ├─ steps*          ; non-checkbox child bullets (R7) or checkbox Steps
   │  ├─ verification?   ; command + expected-output pairs (R10)
   │  ├─ literal*        ; embedded write-through blocks (R12)
   │  └─ Task*           ; subtasks (checkbox children)
   └─ prose*
```

Invariants:
- A Task may be an interior node (Kiro groups): its effective state is
  derived from children when it has any (`done` iff all children done).
- Ids are opaque strings with a parsed sort key `(1 2)` for "1.2", `(101)`
  for "T101"; comparison and renumbering go through the key, never the string.
- Every node records which recognizer produced it and at what confidence
  (exact | loose); lint and views can filter on this.

## 2. Recognizers

Line-level (regex-class, cheap, run on every line):

```
R1  task-line     := ^ indent "- [" state-char "]" sp rest
    state-char    := " "→open  "x"|"X"→done  "-"|"~"→in-progress  other→unknown(keep)
R2  task-id       := ("T" digits) ("." digits)*          ; speckit, T001.1 seen wild
                   | digits ("." digits)*  "."?          ; kiro "1." / "1.2"
R3  tag           := "[" token "]" | bare-story
    bare-story    := "US" digits (wild speckit: brackets optional)
    known tokens  : "P"→parallel, "US"n→story, else→label
R5  inline-dep    := "(depends on" sp ref-list ")"       ; anywhere in rest
R6a trace-req     := "_Requirements:" sp id-list "_"     ; kiro (own bullet line)
R6b path-ref      := "`" path (":" line)? "`"            ; description or bullets
R10a verify-line  := ("Run:"|"Expected:"|"Verify:") sp text   ; superpowers
```

Block-level (structure, run on the markdown/tree-sitter outline):

```
R4  group         := heading whose subtree contains ≥1 task-line
                   | task-line whose children include task-lines (interior task)
    group-meta    := "**"("Purpose"|"Goal"|"Independent Test"|"Checkpoint"
                        |"Files"|"Spec")"**:" | "**Checkpoint**:" solo line
R7  step          := plain "- " bullet child of a task (no checkbox)
                   | "- [ ] **Step" n ":" title "**" (superpowers checkbox step)
R9  file-manifest := "**Files:**" block with (Create|Delete|Rewrite|Modify)":" path lines
                   | frontmatter key files_modified
R10 verification  := run of verify-lines, or fenced block following a
                     "Verify" step, + expected output
R11 frontmatter   := leading "---" YAML "---"; known keys get typed handling
                     (depends_on, requirements, files_modified, wave, phase),
                     unknown keys preserved opaque
R12 embedded-lit  := fenced block introduced by "with exactly this content"
                     -type phrases or inside an <action> element; carries
                     target path when one is named nearby
```

XML-body dialect (GSD): `<tasks>/<task>` elements map onto Group/Task with
`<name>`, `<files>`, `<read_first>`, `<action>` filling the corresponding
fields; checkbox recognizers still run inside `<action>` content.

## 3. Dialect profiles

Detection is per-file, by scoring which id/trace forms occur; mixed files get
the highest-scoring profile with per-node exceptions. The profile only
matters for *emission* (what insert/renumber write) — recognition always
runs the full union.

| Profile | Detect by | Id emission | Dep emission | Trace emission | Grouping emission |
|---|---|---|---|---|---|
| `speckit` | `T\d+` ids | next `Tnnn` | `(depends on Tnnn)` | `[USn]` tag + path-ref | `## Phase n:` |
| `kiro` | decimal ids + `_Requirements:` | next `n.m` (renumber-aware) | `(depends on n.m)` | `_Requirements: …_` bullet | parent task |
| `superpowers` | `### Task n:` + `**Step` | task/step numbers | prose | spec-section refs | `### Task n:` |
| `gsd` | XML `<tasks>` + GSD frontmatter | none | frontmatter `depends_on` | frontmatter `requirements` | `<task>` element |
| `plain` | fallback | none | none | path-ref only | nearest heading |

## 4. Degradation ladder

1. No checkboxes at all → outline/narrowing only (generic markdown layer).
2. R1 only → state toggling, progress counts, next-open-task (document order).
3. +R2 → stable addressing, resolvable deps, insert-with-id.
4. +R4/R7 → tree ops (complete-with-children, promote step→task).
5. +R5/R6 → dependency-aware next-task, trace navigation, coverage/staleness.
6. +R9–R12 → agent-execution support: context bundles, verification runner,
   write-through of embedded literals.

Each command below declares the rung it needs; below that rung it either
disables or falls back (stated per command).

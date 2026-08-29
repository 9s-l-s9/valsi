# Implementation Plan

Sample plan/tasks artifact used by `make run`.  It exercises the plan
grammar's recognizers: numbered tasks with parents, requirement traces,
`**Files:**` and `**Verify:**` meta labels, tags, and dependencies.
Edit it freely; nothing depends on its content.

## Phase 1: Recognizers

- [x] 1. Parse headings into groups
  - Nested headings become nested groups
  - _Requirements: 1.1_
- [x] 1.1 Recognize task checkboxes `- [ ]`, `- [x]`, `- [-]`
  - **Files:** `lisp/valsi-parse.el`
  - **Verify:** `make test`
  - _Requirements: 1.1, 1.2_
- [ ] 1.2 Recognize requirement traces on the line after a task
  - _Requirements: 1.3_

## Phase 2: Commands

- [ ] 2. Navigation and toggling #ui
  - **Verify:** open this file, `C-c n n` moves between tasks
- [ ] 2.1 Toggle state at point with `C-c n t` (depends: 1.1)
  - Cycle `[ ]` -> `[-]` -> `[x]`
- [ ] 2.2 Follow a path-ref like `lisp/valsi-plan.el:46` with `C-c n RET`
  - _Requirements: 2.1_
- [-] 2.3 Show progress with `C-c n %`

## Phase 3: Cross-artifact

- [ ] 3. Report requirement coverage across files (depends: 1.2, 2.2)
  - **Files:** `doc/plan-cross-artifact.md`

---
name: plan-linter
description: Use this skill when reviewing a plan/tasks markdown file for dangling dependencies, duplicate task ids, or leftover template placeholders before handing the plan to an agent.
version: 0.1.0
allowed-tools: Read, Grep
---

# Plan linter

A prompt-file that drives Valsi's plan lint over a spec directory.

## Instructions

1. Open the target `tasks.md`.
2. Run the lint recognizers.
3. Report each finding with its task id.

## References

- `design/plan-commands.md`

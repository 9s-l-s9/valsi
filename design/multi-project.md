# Multiple projects in Valsi

Status: implemented and verified, 2026-10-03.

## Reference and intent

Herdr organizes real agent terminals into project workspaces, retaining their
panes when switching and rolling attention up to a project list. Its useful
interaction is: see the projects, enter the one that needs you, and return to
exactly the work you left. References:

- https://herdr.dev/docs/concepts/
- https://herdr.dev/docs/agents/
- https://herdr.dev/docs/session-state/

Valsi uses that navigation model with its existing native artifact views
and Eat terminals. The hierarchy is **Projects → project hub → artifact or
agent**. Project switching restores the project's Emacs windows in that frame.
An overview can be reached from every level, including a terminal. Ordinary
Emacs buffers, windows and project.el remain usable.

## Interaction contract

- `M-x valsi-projects` opens the working-project overview from anywhere.
  `M-x valsi` still opens the current project hub, falling back to Projects
  outside a project; a prefix argument explicitly opens Projects.
- `P` opens Projects and `w` switches projects in Valsi Browse views. Editable
  artifacts and terminals use `C-c n P` and `C-c n w`; `M-n` lists these actions.
- The overview uses the same faces, sections, stable rows and refresh behavior
  as the hub. `n`/`p` move, `RET` resumes a project or opens a child row, `TAB`
  folds a project, `c` opens its hub, `a` opens its agent, `g` refreshes, `/`
  filters, `+` adds a project and `-` removes it from the working set.
- Project headings always show a path as well as a name. Each project contains
  artifact attention and named agent rows. Counts distinguish a pending scan,
  an empty completed scan, a scan error and an unavailable directory.
- Opening another project saves and restores frame-local window layouts,
  selected buffers, point, hub filters and folds. It never stops a terminal,
  saves an artifact, or starts an agent implicitly. Missing saved buffers fall
  back to the hub. Going to Projects does not replace the saved layout.
- Adding a project uses project.el's known-project completion and supports a
  new directory recognized by a project backend. Only explicitly added roots
  are persisted in Emacs's user state directory. Projects opened in this
  session also appear. Removal forgets this UI membership, never files or
  processes; live agents prevent removal until explicitly stopped.

## Identity and boundaries

Canonical execution roots identify projects, including distinct Git worktrees.
Basenames are labels, never keys. Hub, sidebar, command rail, source views and
terminal names must not collide when two roots or artifacts share a name.
The later logical-repository/worktree model in `multi-agent.md` remains separate.

Agent process liveness is known; working, blocked and completed task states
cannot be inferred from it. Valsi displays running/stopped and optional
explicit task/status reports. Backend reporting remains outside AAP and does
not read terminal cells. A server daemon, remote machines, automatic worktree
creation and automatic agent restart are separate features, not prerequisites
for working across projects in this Emacs session.

## Implementation and verification

1. Add canonical project identity and a working-set registry. Prove duplicate
   basenames, symlink aliases and persistence without source-file changes.
2. Add a Projects view over the existing shared, chunked snapshots. Show
   attention and agents, retain selection, isolate errors, avoid scanning all
   remembered project.el projects, and clean subscriptions on close/removal.
3. Implement frame-local project resume and a consistent navigation vocabulary
   throughout hubs, sources, outlines, tables and terminals. Test two-project
   keyboard journeys, split layouts, unsaved text and running process survival.
4. Wire process lifecycle changes and explicit status reporting into both
   project and aggregate views. Test exit, closed terminals and stale reports;
   preserve the CLI's original sentinel and keyboard input.
5. Document commands and limits, run all gates, and inspect an actual rendered
   two-project overview at narrow and wide widths. Completion requires evidence
   for every interaction above, not only a working project picker.

## Verification

All five implementation steps above are complete. The 13 integration tests in
`test/valsi-projects-test.el` cover the following behavior:

| Requirement | Evidence |
| --- | --- |
| Stable identity and membership | Duplicate basenames, symlink aliases, persistence round-trip, corrupt-state preservation, add/remove commands and unavailable roots |
| Shared asynchronous snapshots | No discovery on initial display, one scan shared with the hub, isolated backend failure, selection/filter/fold continuity and subscription cleanup |
| Project resume | Split-window restoration, saved point, live process survival, unsaved source preservation and fallback after a selected source closes |
| Consistent navigation | Browse and terminal-safe bindings, keyboard activation, symmetric row navigation, width changes and visible paths while folded |
| Source isolation | Separate outlines, tables, diagnostics and concurrent plan reviews for identically named artifacts |
| Agent state | Independent named instances, live status propagation to both views, original sentinel execution and rejection of stale reports |
| Background scope | Edits update their own project; remembered remote roots do not trigger path resolution or scans |

`make check` passes all 240 ERT tests, compilation with warnings treated as
errors, Checkdoc and metadata validation. The extension test target passes,
and the Texinfo manual builds. An isolated terminal Emacs smoke check used
two real Git projects named `app`, an unsaved plan and a live pipe process
representing an agent. The overview was inspected at 80 and 140 columns,
including automatic resizing and keyboard navigation. This verifies native
terminal rendering and project-backend discovery; it does not claim a live
backend conversation or automatic task-state integration.

Automatic backend task reports, process recovery after Emacs exits, remote
session management and worktree creation remain separate follow-up features.
They are not presented by this implementation as available behavior.

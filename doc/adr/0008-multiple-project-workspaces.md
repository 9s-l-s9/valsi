# 8. A working-project overview above project hubs

Date: 2026-10-02

## Status

Accepted and implemented; verification recorded in `design/multi-project.md`.

## Context

Valsi associates scans and terminal instances with canonical project roots, but
navigation assumes one project and application buffer names use basenames.
Working on two repositories with the same name can reuse the wrong hub. Users
also need to see attention across repositories and resume their previous work
without rebuilding the terminal/artifact layout each time.

## Decision

Use a small client-side working-project registry and a native Projects view
above existing project hubs. Canonical execution directories are identities;
paths disambiguate labels. Project.el supplies project discovery and completion.
Explicit additions persist root declarations only in the Emacs state directory.
Window layouts live per frame and per root for this Emacs session.

The Projects view subscribes to the same chunked snapshots as hubs, with no
second artifact index. It renders known state immediately, and adds attention
and terminal rows per project. Navigation restores windows without recreating
processes. Source content remains authoritative and is never saved as a side
effect of switching. Shared keys and command menus expose Projects and Switch
project from every native Valsi surface and terminal-safe prefix bindings.

Agent liveness and explicit status reports are separate facts. Lifecycle events
update views without replacing the terminal emulator's sentinel. No terminal
screen scraping, transcript persistence or agent execution is added to AAP.

## Consequences

Projects with identical basenames and linked worktrees remain isolated. A
working set limits background discovery to projects the user has opened or
added. Unavailable projects and failed scans remain visible and individually
recoverable. Closing the overview releases its own subscriptions; an open hub
may continue watching. Removing a project cannot stop an agent or delete files.

Layouts and terminals do not survive Emacs termination through this feature.
Project-root declarations do. Backend task-state integration requires explicit
reports; a running process is never presented as proof that a task is working
or complete. Herdr's daemon, remote transport and screen detection are not
introduced into the artifact application.

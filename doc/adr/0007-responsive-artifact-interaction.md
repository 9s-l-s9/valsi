# 7. Keep project analysis off direct artifact interaction

Date: 2026-10-02

## Status

Accepted.

## Context

Interaction profiling exposed work that the parse-only performance tests did
not cover. Opening the contextual sidebar scanned the project and parsed each
recognized artifact twice. Reentering the hub reset its major mode, discarding
folds and filters. Opening or explicitly refreshing a source artifact parsed it
twice as well. Dependency lint walked the graph again for every task, with a
linear task lookup at each step. A 600-task chain exceeded Emacs's evaluation
depth; the hub caught the error and displayed zero warnings.

The user-facing problem includes continuity as well as elapsed time. A view
that forgets the selected row, or a state toggle that requires leaving Browse,
interrupts the artifact workflow even when its individual operations are fast.

## Decision

Source buffers synchronize their full, widened text once per text revision and
grammar registry revision. Text properties do not invalidate the model.
Semantic queries synchronize immediately when necessary; ordinary editing
schedules a coalesced idle refresh. The client still owns its copied tree and
buffer-coordinate translation. Fontification follows normal visible-region
redisplay rather than eagerly processing the entire document.

Project analysis caches trees, summaries, and structural plan warnings by disk
signature, visiting buffer and text revision, grammar revision, and read limit.
Disk signatures include modification time, size, inode, and file type. Buffer
edits refresh affected cached entries without rediscovering the project. A
filesystem event upgrades a pending edit refresh to a full reconciliation.
Opening the hub and explicit refresh always reconcile against the filesystem;
notifications remain hints. Filesystem-dependent diagnostics are recomputed on
full scans, including changes to references in otherwise unchanged plans.

Subscribers share one reconciled snapshot per dispatch. The sidebar displays
source context immediately and schedules project analysis for idle time. Point
motion uses the already-associated sidebar instead of discovering the project
after every key. Returning to an existing hub preserves its view state.

Dependency-cycle detection uses iterative strongly connected components, with
linear graph work and no recursion proportional to dependency depth. Every
member of a cycle is reported; tasks that only depend on a cycle are not cycle
members. Duplicate ids retain the existing first-definition lookup semantics.

Effective task states and progress counts likewise use one bottom-up traversal
per operation. Parents derive their state from descendant leaves; progress
counts the leaves once. Lint and actionable-task selection reuse that operation's
state index, avoiding exponential descendant recomputation in completed chains.

Hub file rows carry stable identities scoped to their section, so a file also
appearing in Active does not steal selection from its family row. Opening,
editing, and handoff resolve the button on the selected line. Attention entries
and their overflow are actual buttons; next/previous navigation advances rows
regardless of the cursor's column. Explicitly opening an artifact through the
hub enables its grammar independently of global automatic activation.

Browse exposes common semantic actions directly. An explicit toggle may change
the source while remaining in Browse, but it cannot override read-only state
that predates Valsi. Free text editing still uses Insert. Agent interaction
continues to belong to the terminal and remains outside AAP.

## Consequences

Cached trees consume memory proportional to recognized project content. They
are invalidated by grammar registration/removal and discarded for files that
leave the index. Closing the last subscriber detaches observation hooks and
timers; the snapshot can be reused on the next visit. Explicit refresh remains
the fallback on filesystems without useful notifications.

Idle work still executes in the Emacs process. Very large artifacts or a cold
project discovery can therefore take perceptible time; this change does not
claim background-thread parsing. `make benchmark` measures the complete paths,
and ERT checks work counts, long chains, cache invalidation, narrowing, disk
conflicts, and continuity independently of machine speed.

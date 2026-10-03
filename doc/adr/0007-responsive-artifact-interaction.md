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

Follow-up profiling found quadratic sibling insertion beneath the parse cache:
appending each node walked all preceding siblings. At 8,000 flat tasks the
append helper alone took 483 ms. Family dashboards also lost their rows on
refresh because their callbacks parsed the rendered table instead of the source
artifact; opening another dashboard could overwrite their shared Enter binding.

## Decision

Source buffers synchronize their full, widened text once per text revision and
grammar registry revision. Text properties do not invalidate the model.
Semantic queries synchronize immediately when necessary; ordinary editing
schedules a coalesced idle refresh. The client still owns its copied tree and
buffer-coordinate translation. Fontification follows normal visible-region
redisplay rather than eagerly processing the entire document.

Each parse keeps a temporary table of child-list tails so appending nodes does
constant work per sibling. Child lists stay in document order during parsing;
the temporary table is discarded on return. Neither the public node structure
nor its serialized representation gains cache fields.

Project analysis caches trees, summaries, and structural plan warnings by disk
signature, visiting buffer and text revision, grammar revision, and read limit.
Disk signatures include modification time, size, inode, and file type. Buffer
edits refresh affected cached entries without rediscovering the project. A
filesystem event upgrades a pending edit refresh to a full reconciliation.
Opening the hub and explicit refresh always reconcile against the filesystem;
notifications remain hints. Filesystem-dependent diagnostics are recomputed on
full scans, including changes to references in otherwise unchanged plans.

Hub opens and explicit refreshes schedule reconciliation rather than finishing
it inside the command. Candidate filtering, cache checks, per-file analysis,
missing-file reconciliation, and revision validation yield between files.
Each timer turn processes at most 32 steps or about 10 ms of work, checking for
pending input between steps. Continuations use a positive ordinary timer delay
so they yield to the command loop even during one uninterrupted idle period.
File/edit notifications still use an initial idle debounce.

Subscribers share one scan and its completed snapshot. Until it is ready, views
retain the previous rows with a refreshing indicator; a cold sidebar can already
show source context. Analysis cache entries can be reused from a cancelled pass,
but disk baselines and published rows are committed only after reconciliation
and revision checks succeed. Edits and filesystem events invalidate in-flight
work, and revision validation catches changed sources or grammar registrations
even without a notification. Old timer callbacks cannot publish after a newer
request, project reset, or final subscriber closure. A failed scan leaves the
last snapshot visible and reports an error that explicit refresh can retry.

Point motion uses the already-associated sidebar instead of discovering the
project after every key. Returning to an existing hub preserves its view state.

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

Family tables retain their source buffer and invoke refresh callbacks in its
widened context while preserving its point and restriction. Reopening the same
table preserves sorting and row selection. Enter bindings are local to each
table, and positional rows navigate to the recorded source rather than guessing
from recently visited buffers. Closing that source leaves the last table visible;
refresh and positional navigation report that its source has been closed.

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

Work still executes in the Emacs process. The time budget is checked between
operations: a single parser, filesystem call, garbage collection, final render,
or project backend's initial file listing can exceed it. Chunking introduces
small pauses and can increase total scan time while reducing uninterrupted work.
`make benchmark` reports initial hub display, longest work turn, and total
completion time alongside synchronous analysis costs. ERT checks bounded steps,
pending input, shared snapshots, cancellation, interleaved changes, retry, and
an unrelated real timer running before scan completion, as well as the existing
cache, disk-conflict, and continuity guarantees.

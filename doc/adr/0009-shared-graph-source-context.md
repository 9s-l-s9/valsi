# 9. Share one grammar context between graph sources

Date: 2026-11-12

## Status

Accepted

## Context

Each graph source previously reopened every Markdown file and independently
recognized links. More sources multiplied file reads, bypassed artifact
detection, and treated fenced examples or unrelated prose as relationships.
Ignored errors made incomplete graphs indistinguishable from complete ones.

## Decision

Read each candidate file into one temporary buffer, detect its grammar through
the registry, and parse it once when an applicable source exists. Bind the
grammar ID and parsed tree while invoking sources in the shared read-only
buffer. Preserve the existing one-file-argument source API; registration gains
an optional list of grammar IDs, with nil retaining unrestricted sources.
Built-in sources derive edges from nodes produced by their declared grammar.

Collect directory, file, parser, and individual source failures as visible
error rows. Continue collecting unaffected files and sources.

## Consequences

Built-in extraction performs one read and at most one parse per file. Plugins
can adopt the shared context without changing their argument list; legacy
plugins that reopen the path still incur their own reads. Plugins must treat
the shared tree as immutable. No graph cache is introduced, so refreshes see
current disk content and current grammar registrations. The graph remains a
synchronous, in-process artifact query outside the AAP method surface.

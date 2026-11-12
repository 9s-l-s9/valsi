# Valsi artifact bridge for Pi

This optional Pi extension adds artifact-aware, read-only tools to stock Pi.
Valsi launches Pi normally in an Eat terminal and passes this extension with
`--extension` when available. Pi continues to own its prompt, tools,
permissions, authentication, models, sessions, and transcript.

The extension registers only the `valsi_artifact` AAP bridge. It starts a
private headless Emacs AAP server on demand and speaks strict-LF JSON-RPC over
stdio. The available actions are `capabilities`, `symbols`, and `plan_context`
(which also requires `taskId`). `path` is relative to the current project.
Absolute paths, traversal outside the project, and symlinks to outside files
are rejected. Documents are closed after each query, including failures and
cancellations. Concurrent queries of the same file run in order; different
files can be queried independently.

`symbols` returns compact JSON with a flat `nodes` array, each node's original
fields except `children`, and its `depth` (root is 0). Use `maxDepth` (0–64) or
`nodeTypes` (for example `["task"]`) to filter. `maxNodes` defaults to 200 and
can be 1–500. Each symbols result is bounded to 32 KiB of compact UTF-8 JSON;
both the tool text and `details` contain only this bounded result.
`truncated: true` and a notice indicate that the node or
byte limit was reached; narrow the query to retrieve a smaller result.

Set `VALSI_AAP_EMACS` to the Emacs executable and
`VALSI_AAP_LISP_DIRECTORY` to the directory containing `valsi-server.el` to
override automatic discovery. The legacy mixed-case spellings
`Valsi_AAP_EMACS` and `Valsi_AAP_LISP_DIRECTORY` are still accepted; uppercase
values take precedence when both are set.

There is deliberately no Valsi authentication, session, transcript, approval,
or tool-policy layer here. Without this extension Pi remains a fully capable
coding agent; only Valsi-specific artifact resolution degrades to plain
terminal references.

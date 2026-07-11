# Valsi artifact bridge for Pi

This optional Pi extension adds artifact-aware, read-only tools to stock Pi.
Valsi launches Pi normally in an Eat terminal and passes this extension with
`--extension` when available. Pi continues to own its prompt, tools,
permissions, authentication, models, sessions, and transcript.

The extension registers only the `valsi_artifact` AAP bridge. It starts a
private headless Emacs AAP server on demand and speaks strict-LF JSON-RPC over
stdio. The available actions are `capabilities`, `symbols`, and `plan_context`
(which also requires `taskId`). `path` is relative to the current project.

There is deliberately no Valsi authentication, session, transcript, approval,
or tool-policy layer here. Without this extension Pi remains a fully capable
coding agent; only Valsi-specific artifact resolution degrades to plain
terminal references.

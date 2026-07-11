# Pi RPC 0.80.6 compatibility fixtures

These strict-LF JSONL records pin the portion of Pi's RPC contract consumed by
Valsi. They are derived from the checked-in Pi 0.80.6 sources:

- `packages/coding-agent/src/modes/rpc/rpc-types.ts`
- `packages/coding-agent/src/modes/rpc/jsonl.ts`
- `packages/coding-agent/src/core/agent-session.ts`
- `packages/agent/src/types.ts`

`requests.jsonl` locks request spelling and JSON field casing.
`responses.jsonl` locks response correlation, the required `get_state` fields,
streaming message events, tool lifecycle events, settlement, and an embedded
U+2028 character that must not be treated as a record delimiter.

Only deterministic values belong here. A deliberate Pi upgrade must update the
pin, inspect the upstream types, regenerate or review these traces, and run the
fixture tests plus the live Guix smoke test.

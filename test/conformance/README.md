# AAP v0 conformance suite

Machine-checkable conformance tests for the Agent Artifact Protocol, versioned
`v0`. The normative contract is [`doc/aap-spec.md`](../../doc/aap-spec.md); this
suite is its executable form.

## Running

```sh
make conformance      # just this suite
make check            # runs it as part of the full ERT suite
```

## What it asserts

Everything is exercised through the single transport-neutral request boundary
(`METHOD` + `PARAMS` → response), so the suite is server-implementation-agnostic:

- `initialize` advertises the required v0 method set; unknown methods return
  `:error` rather than crashing the transport.
- `grammar/list` includes the `generic` fallback; `grammar/detect` /
  `grammar/describe` behave per spec.
- `artifact/didOpen` → `didChange` → `didClose` lifecycle, with monotonic
  `version` and `capabilities` that agree between `didOpen` and
  `artifact/capabilities`.
- `artifact/symbols` returns a node tree honoring the v0 **node-model
  invariants** — typed, `exact|loose` confidence, 0-based bounded offsets, child
  containment, and to-JSON/from-JSON round-trip.
- `grammar/register` **hot-reloads**: a grammar registered into the running
  server re-resolves already-open documents with no reopen.

## Certifying a non-Emacs server

The reference server is the elisp `valsi-proto`. To run this suite against another
implementation, bind `valsi-aap-request-function` to a client of that server
(anything with the signature `(method params) → response-plist`) and provide the
node-model JSON shape from `doc/aap-spec.md` §5. Passing the suite is the v0
conformance bar. A second independent implementation passing it is the trigger to
promote AAP from "extracted spec" to "standard" (v1.x, Sprint 12).

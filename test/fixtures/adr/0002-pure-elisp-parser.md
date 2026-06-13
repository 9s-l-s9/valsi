# 2. Pure-elisp recognizers; no tree-sitter dependency; Guix toolchain

Date: 2026-07-13

## Status

Accepted. Records the parser strategy, the build toolchain, and the pinned Emacs
floor (the latter verified in Sprint 0, T005).

## Context

Valsi's parse layer (`valsi-parse`) turns plain markdown into the typed node model.
Two implementation strategies were considered: (a) the tree-sitter markdown
grammar + a semantic layer, or (b) hand-rolled pure-elisp line/block recognizers.
The maintainer chose **plain Makefile + ERT, pure-elisp, no tree-sitter
dependency, reproducible Guix package** (tooling decision, 2026-07-13).

Separately, tree-sitter's *style* (declarative grammar-as-data + S-expression
queries + robust/error-tolerant parsing) is attractive and compatible with the
descriptive thesis — but that is a **style to borrow when extracting a grammar
format (Sprint 8)**, not a reason to take the tree-sitter *engine* as a
dependency. See the "Grammars are yours to define" principle in `PLAN.md`.

## Decision

- **Pure-elisp recognizers**, no tree-sitter runtime/grammar dependency.
  Incremental reparse over changed regions (markers, not offsets).
- **Toolchain**: `Makefile` + ERT; grammars/model run inside Emacs; reproducible
  **Guix** package (`valsi.scm`); `jsonrpc.el` (built in) for the AAP transport
  (ADR 0004).
- **Emacs floor: 29.1**; **dev/CI runs on 30.2** (what Guix currently provides).
  29.1 gives mature `jsonrpc.el`, bundled eglot (client reference), `secure-hash`,
  `base64url-encode-string`, and `make-network-process` — everything
  `valsi-agent-auth` (research/03a) and the server/client need, without
  tree-sitter.

## Verification (T005, 2026-07-13)

```
guix shell nss-certs emacs emacs-markdown-mode emacs-package-lint -- \
  emacs --batch --eval "(progn (require 'markdown-mode) (require 'package-lint) …)"
→ TOOLCHAIN_OK emacs-version=30.2   (exit 0)
```

`emacs`, `emacs-markdown-mode`, and `emacs-package-lint` all resolve under Guix
and load; the reproducible dev shell is viable. (`emacs`, `makeinfo`, `curl` are
not on the base PATH here — they come via `guix shell`, as expected.)

## Consequences

- **Positive**: no native grammar install, no Emacs-29-tree-sitter requirement,
  fully controllable descriptive/degradation behaviour, reproducible builds.
- **Negative**: we hand-write recognizers (cheap — they're line/block regex
  classes) and own incremental-reparse performance (profiled in Sprint 10,
  T1003). If a pure-elisp parser proves too slow on very large files, revisiting
  tree-sitter as an *optional* accelerated backend remains open — this ADR is the
  record of that trade-off.
- **Neutral**: the tree-sitter-*style* declarative grammar format + query layer
  can still be adopted at Sprint 8 without adopting the engine.

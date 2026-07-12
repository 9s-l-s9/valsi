# Valsi -- Makefile (plain Makefile + ERT, pure-elisp, Guix-reproducible)
# Usage: `make check`  or  `make guix-check`
#        `make run`    launches a demo Emacs with Valsi loaded.

EMACS ?= emacs
GUIX  ?= guix
BUN   ?= bun

# Load order matters (dependencies first).
SRC = lisp/valsi-node.el lisp/valsi-parse.el lisp/valsi-view.el \
      lisp/valsi-registry.el lisp/valsi-proto.el lisp/valsi-server.el \
      lisp/valsi-harness.el lisp/valsi-pi.el lisp/valsi-plan.el \
      lisp/valsi-instruction.el lisp/valsi-promptfile.el lisp/valsi-memory.el \
      lisp/valsi-changelog.el lisp/valsi-decision.el lisp/valsi-overview.el \
      lisp/valsi-graph.el \
      lisp/valsi-terminal-agent.el lisp/valsi-app-live-refresh.el lisp/valsi-app.el \
      lisp/valsi-plan-review.el lisp/valsi-plan-agent.el \
      lisp/valsi.el
ELC = $(SRC:.el=.elc)

BATCH = $(EMACS) -Q --batch -L lisp -L test -L test/conformance

.PHONY: all check check-all compile test test-extension conformance lint clean \
	run demo guix-check guix-check-all guix-test-extension \
	guix-profile-smoke help

all: check

help:
	@echo "make compile  byte-compile (warnings->errors)"
	@echo "make test     run ERT suite"
	@echo "make test-extension  run Pi extension tests with Bun"
	@echo "make lint     checkdoc"
	@echo "make check    compile + checkdoc + test"
	@echo "make run      launch demo Emacs with Valsi"
	@echo "make guix-check  run 'make check' inside 'guix shell'"
	@echo "make guix-check-all  run Emacs and extension gates in Guix"
	@echo "make guix-profile-smoke  build installed package and require it in Emacs -Q"

compile: clean
	$(BATCH) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(SRC)

%.elc: %.el
	$(BATCH) -f batch-byte-compile $<

test:
	$(BATCH) -l ert -l test/valsi-test.el \
	  -l test/valsi-app-live-refresh-test.el \
	  -f ert-run-tests-batch-and-exit

test-extension:
	$(BUN) test extensions/valsi-pi/test/*.test.mjs

# Run only the AAP conformance suite (what a third-party implementation runs).
conformance:
	$(BATCH) -l ert -l test/conformance/aap-conformance.el \
	  --eval "(ert-run-tests-batch-and-exit \"^valsi-aap-conformance-\")"

lint:
	$(BATCH) --eval "(mapc #'checkdoc-file '($(patsubst %,\"%\",$(SRC))))"

check: compile lint test
	@echo "Valsi: check OK"

check-all: check test-extension
	@echo "Valsi: all checks OK"

# Reproducible entry: run the whole check inside a pinned guix shell.
guix-check:
	$(GUIX) shell -D -f valsi.scm -- $(MAKE) check EMACS=emacs

guix-test-extension:
	$(GUIX) shell bun -- bun test extensions/valsi-pi/test/*.test.mjs

guix-check-all: guix-check guix-test-extension
	@echo "Valsi: all Guix checks OK"

# Prove the consumer workflow, not only source-tree compilation.  In
# particular, this catches missing EMACSLOADPATH package search metadata.
guix-profile-smoke:
	$(GUIX) shell -f valsi.scm -- $(EMACS) -Q --batch \
	  --eval "(progn (require 'valsi) (princ (locate-library \"valsi\")))"

# Launch an interactive demo Emacs with Valsi loaded on PLAN.md.
run demo:
	$(GUIX) shell -D -f valsi.scm -- $(EMACS) -Q -L lisp -l valsi-demo.el

clean:
	rm -f $(ELC)

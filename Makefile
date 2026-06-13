# Valsi -- Makefile (plain Makefile + ERT, pure-elisp, Guix-reproducible)
# Usage: `make check`  or  `guix shell -m manifest -- make check`
#        `make run`    launches a demo Emacs with Valsi loaded.

EMACS ?= emacs
GUIX  ?= guix
GUIX_PKGS = nss-certs emacs emacs-markdown-mode

# Load order matters (dependencies first).
SRC = lisp/valsi-node.el lisp/valsi-parse.el lisp/valsi-view.el \
      lisp/valsi-registry.el lisp/valsi-proto.el lisp/valsi-plan.el \
      lisp/valsi-instruction.el lisp/valsi-promptfile.el lisp/valsi-memory.el \
      lisp/valsi-changelog.el lisp/valsi-decision.el lisp/valsi-overview.el \
      lisp/valsi-graph.el lisp/valsi.el
ELC = $(SRC:.el=.elc)

BATCH = $(EMACS) -Q --batch -L lisp -L test

.PHONY: all check compile test lint clean run demo guix-check help

all: check

help:
	@echo "make compile  byte-compile (warnings->errors)"
	@echo "make test     run ERT suite"
	@echo "make lint     checkdoc"
	@echo "make check    compile + test"
	@echo "make run      launch demo Emacs with Valsi"
	@echo "make guix-check  run 'make check' inside 'guix shell'"

compile: clean
	$(BATCH) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(SRC)

%.elc: %.el
	$(BATCH) -f batch-byte-compile $<

test:
	$(BATCH) -l ert -l test/valsi-test.el -f ert-run-tests-batch-and-exit

lint:
	$(BATCH) --eval "(mapc #'checkdoc-file '($(patsubst %,\"%\",$(SRC))))"

check: compile test
	@echo "Valsi: check OK"

# Reproducible entry: run the whole check inside a pinned guix shell.
guix-check:
	$(GUIX) shell $(GUIX_PKGS) -- $(MAKE) check EMACS=emacs

# Launch an interactive demo Emacs with Valsi loaded on PLAN.md.
run demo:
	$(GUIX) shell $(GUIX_PKGS) -- $(EMACS) -Q -L lisp -l valsi-demo.el

clean:
	rm -f $(ELC)

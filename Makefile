# Valsi -- Makefile (plain Makefile + ERT, pure-elisp, Guix-reproducible)
# Usage: `make check`  or  `make guix-check`
#        `make run`    launches a demo Emacs with Valsi loaded.

EMACS ?= emacs
GUIX  ?= guix
# The extension tests are node:test files; Bun runs them too (CI uses Bun).
NODE  ?= node
MAKEINFO ?= makeinfo

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
TESTS = $(sort $(wildcard test/*-test.el))

BATCH = $(EMACS) -Q --batch -L lisp -L test -L test/conformance

.PHONY: all check check-all compile ensure-emacs test test-extension \
	conformance lint verify-meta info clean \
	run demo guix-check guix-check-all guix-test-extension \
	guix-profile-smoke help

all: check

help:
	@echo "make compile  byte-compile (warnings->errors)"
	@echo "make test     run ERT suite"
	@echo "make test-extension  run Pi extension tests (node --test; NODE=bun works too)"
	@echo "make lint     checkdoc"
	@echo "make verify-meta  check version/URL/deps agree with lisp/valsi.el"
	@echo "make info     build doc/valsi.info from the texinfo manual"
	@echo "make check    compile + checkdoc + verify-meta + test"
	@echo "make run      launch demo Emacs with Valsi"
	@echo "make guix-check  run 'make check' inside 'guix shell'"
	@echo "make guix-check-all  run Emacs and extension gates in Guix"
	@echo "make guix-profile-smoke  build installed package and require it in Emacs -Q"

# Fail early with a hint when no Emacs is available (e.g. outside guix shell).
ensure-emacs:
	@command -v $(EMACS) >/dev/null 2>&1 || { \
	  echo "valsi: '$(EMACS)' not found."; \
	  echo "  Try 'make guix-check', or 'make check EMACS=/path/to/emacs'."; \
	  exit 1; }

compile: ensure-emacs clean
	$(BATCH) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(SRC)

%.elc: %.el
	$(BATCH) -f batch-byte-compile $<

# Every test/*-test.el is loaded; valsi-test.el requires the conformance suite.
test:
	$(BATCH) -l ert $(patsubst %,-l %,$(TESTS)) \
	  -f ert-run-tests-batch-and-exit

test-extension:
	$(NODE) --test extensions/valsi-pi/test/*.test.mjs

# Run only the AAP conformance suite (what a third-party implementation runs).
conformance:
	$(BATCH) -l ert -l test/conformance/aap-conformance.el \
	  --eval "(ert-run-tests-batch-and-exit \"^valsi-aap-conformance-\")"

lint:
	$(BATCH) --eval "(mapc #'checkdoc-file '($(patsubst %,\"%\",$(SRC))))"

# lisp/valsi.el's header is the single source of truth for the version, URL
# and hard dependencies (package.el, MELPA and Guix all read it).  Everything
# that repeats a fact from it is checked here rather than typed twice.
verify-meta: ensure-emacs
	@$(BATCH) -l lisp-mnt --eval '(with-temp-buffer (insert-file-contents "lisp/valsi.el") (princ (format "%s\n%s\n" (lm-version) (lm-homepage))))' > .meta.tmp
	@v=$$(sed -n 1p .meta.tmp); u=$$(sed -n 2p .meta.tmp); \
	  slug=$${u#https://github.com/}; rm -f .meta.tmp; ok=1; \
	  grep -q "(version \"$$v\")" valsi.scm \
	    || { echo "verify-meta: valsi.scm version != $$v"; ok=0; }; \
	  grep -q "(home-page \"$$u\")" valsi.scm \
	    || { echo "verify-meta: valsi.scm home-page != $$u"; ok=0; }; \
	  grep -q ":repo \"$$slug\"" recipes/valsi \
	    || { echo "verify-meta: recipes/valsi :repo != $$slug"; ok=0; }; \
	  grep -q "^## \[$$v\]" CHANGELOG.md \
	    || { echo "verify-meta: CHANGELOG.md has no ## [$$v] entry"; ok=0; }; \
	  grep -q '"name": "valsi-pi"' extensions/valsi-pi/package.json \
	    || { echo "verify-meta: extension package.json name != valsi-pi"; ok=0; }; \
	  if git remote get-url origin >/dev/null 2>&1; then \
	    o=$$(git remote get-url origin | sed 's#\.git$$##; s#^git@github.com:#https://github.com/#'); \
	    [ "$$o" = "$$u" ] || echo "verify-meta: note: origin ($$o) != URL header ($$u)"; \
	  fi; \
	  [ $$ok = 1 ] && echo "verify-meta: $$v $$u OK"

info: doc/valsi.info

doc/valsi.info: doc/valsi.texi
	$(MAKEINFO) --no-split -o $@ $<

check: compile lint verify-meta test
	@echo "Valsi: check OK"

check-all: check test-extension
	@echo "Valsi: all checks OK"

# Reproducible entry: run the whole check inside a pinned guix shell.
guix-check:
	$(GUIX) shell -D -f valsi.scm -- $(MAKE) check EMACS=emacs

guix-test-extension:
	$(GUIX) shell node -- $(MAKE) test-extension NODE=node

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
	rm -f $(ELC) .meta.tmp doc/valsi.info

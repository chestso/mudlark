# Makefile for tintin-mode Emacs package (mudlark contrib)
#
# Can be invoked directly from this directory or via the emacs-* targets
# in the top-level mudlark Makefile.am (which delegate here).
#
# Variables:
#   EMACS    Emacs binary (default: emacs)
#   prefix   Install prefix (default: $(HOME)/.local)
#   DESTDIR  Staging directory (default: empty)

EMACS ?= emacs
prefix ?= $(HOME)/.local
elprefixdir ?= $(prefix)/share/emacs/site-lisp
DESTDIR ?=

srcdir = $(dir $(lastword $(MAKEFILE_LIST)))

.PHONY: all install uninstall test format clean

all: tintin-mode.elc

tintin-mode.elc: $(srcdir)tintin-mode.el
	$(EMACS) --batch -f batch-byte-compile $<

install: all
	install -d $(DESTDIR)$(elprefixdir)
	install -m 644 $(srcdir)tintin-mode.el tintin-mode.elc $(DESTDIR)$(elprefixdir)/
	@echo "Installed to $(DESTDIR)$(elprefixdir)/"
	@echo "Add (require 'tintin-mode) to your init.el"

uninstall:
	rm -f $(DESTDIR)$(elprefixdir)/tintin-mode.el $(DESTDIR)$(elprefixdir)/tintin-mode.elc

test: $(srcdir)tintin-mode.el $(srcdir)tintin-mode-tests.el
	$(EMACS) --batch \
	  --eval '(add-to-list (quote load-path) "$(srcdir)")' \
	  -l tintin-mode.el -l tintin-mode-tests.el \
	  -f ert-run-tests-batch-and-exit

format:
	$(EMACS) --batch \
	  --eval '(require (quote package))' \
	  --eval '(package-initialize)' \
	  --eval '(dolist (f (list "$(srcdir)tintin-mode.el" "$(srcdir)tintin-mode-tests.el")) (find-file f) (indent-region (point-min) (point-max)) (save-buffer))'
	@command -v prettier >/dev/null 2>&1 && prettier --write $(srcdir)*.md || true

clean:
	rm -f tintin-mode.elc

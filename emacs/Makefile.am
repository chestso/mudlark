EMACS ?= emacs

# Install to the same profile prefix as the rest of mudlark.
emacslispdir = $(datadir)/emacs/site-lisp

emacslisp_DATA = tintin-mode.el

EXTRA_DIST = tintin-mode.el tintin-mode-tests.el COPYING README.md

# --- Optional targets (not hooked into the automake build / install / check
#     because they need Emacs at build time, which is not a configure
#     dependency).  Run these by hand when developing the mode. ---------------

.PHONY: byte-compile test elisp-format

byte-compile: tintin-mode.elc

tintin-mode.elc: tintin-mode.el
	$(EMACS) --batch -f batch-byte-compile $(srcdir)/tintin-mode.el

test: tintin-mode.el tintin-mode-tests.el
	$(EMACS) --batch \
	  --eval '(add-to-list (quote load-path) "$(srcdir)")' \
	  -l tintin-mode.el -l tintin-mode-tests.el \
	  -f ert-run-tests-batch-and-exit

elisp-format:
	$(EMACS) --batch \
	  --eval '(require (quote package))' \
	  --eval '(package-initialize)' \
	  --eval '(dolist (f (list "$(srcdir)/tintin-mode.el" "$(srcdir)/tintin-mode-tests.el")) (find-file f) (indent-region (point-min) (point-max)) (save-buffer))'
	@command -v prettier >/dev/null 2>&1 && prettier --write $(srcdir)/*.md || true

CLEANFILES = *.elc

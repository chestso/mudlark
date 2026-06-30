# Makefile.am - Top-level automake file for mudlark

SUBDIRS = include src lisp tests

ACLOCAL_AMFLAGS = -I m4

EXTRA_DIST = \
    autogen.sh \
    build-aux/git-version.sh \
    version \
    README.md \
    NEWS \
    ChangeLog \
    AUTHORS \
    COPYING \
    .clang-format \
    TODO.md \
    emacs/Makefile \
    emacs/README.md \
    emacs/COPYING \
    emacs/tintin-mode.el \
    emacs/tintin-mode-tests.el

# Format target — clang-format on C, shfmt on shell, prettier on Markdown,
# black on Python, and the Lisp formatter (from the installed ditty
# share dir or sibling checkout) on .lisp files via ditty.
.PHONY: format
format:
	@if command -v clang-format >/dev/null 2>&1; then \
	    echo "Formatting C with clang-format..."; \
	    find $(top_srcdir)/src $(top_srcdir)/include $(top_srcdir)/tests \
	        \( -name '*.c' -o -name '*.h' \) -print0 \
	        | xargs -0 clang-format -i; \
	else \
	    echo "clang-format not found - skipping C formatting." >&2; \
	fi
	@if command -v shfmt >/dev/null 2>&1; then \
	    echo "Formatting shell scripts with shfmt..."; \
	    find $(top_srcdir) -maxdepth 2 -name '*.sh' -print0 2>/dev/null \
	        | xargs -0 -r shfmt -w; \
	else \
	    echo "shfmt not found - skipping shell script formatting." >&2; \
	fi
	@if command -v prettier >/dev/null 2>&1; then \
	    echo "Formatting Markdown with prettier..."; \
	    find $(top_srcdir) -maxdepth 2 -name '*.md' -print0 \
	        | xargs -0 prettier --write; \
	else \
	    echo "prettier not found - skipping Markdown formatting." >&2; \
	fi
	@if command -v black >/dev/null 2>&1; then \
	    echo "Formatting Python with black..."; \
	    find $(top_srcdir) -name '*.py' -not -path '$(top_srcdir)/build/*' -print0 \
	        | xargs -0 -r black -q; \
	else \
	    echo "black not found - skipping Python formatting." >&2; \
	fi
	@repl=""; lisp_fmt=""; \
	if command -v ditty >/dev/null 2>&1; then repl=ditty; fi; \
	for cand in "$$HOME/.local/share/ditty/lisp/lisp-fmt.lisp" \
	            "$(top_srcdir)/../ditty/lisp/lisp-fmt.lisp"; do \
	    [ -f "$$cand" ] && { lisp_fmt="$$cand"; break; }; \
	done; \
	if [ -n "$$repl" ] && [ -n "$$lisp_fmt" ]; then \
	    echo "Formatting Lisp via $$repl ($$lisp_fmt) ..."; \
	    find $(top_srcdir)/lisp -name '*.lisp' -print0 \
	        | xargs -0 -r -n 1 "$$repl" "$$lisp_fmt" -- -i; \
	else \
	    echo "ditty or lisp-fmt.lisp not found - skipping Lisp formatting." >&2; \
	fi
	@if command -v emacs >/dev/null 2>&1; then \
	    echo "Formatting Elisp with emacs..."; \
	    emacs --batch \
	      --eval '(require (quote package))' \
	      --eval '(package-initialize)' \
	      --eval '(dolist (f (list "$(top_srcdir)/emacs/tintin-mode.el" "$(top_srcdir)/emacs/tintin-mode-tests.el")) (find-file f) (indent-region (point-min) (point-max)) (save-buffer))'; \
	else \
	    echo "emacs not found - skipping Elisp formatting." >&2; \
	fi

# ── Emacs contrib (tintin-mode) ──────────────────────────────────────
#
# The emacs/ subdirectory contains the tintin-mode Emacs package as a
# bundled contrib. It has its own standalone Makefile (not autotools)
# that handles byte-compilation, testing, formatting, and installation.
# These targets delegate to it, passing the configured prefix through.
#
# Usage:
#   make emacs          # byte-compile
#   make emacs-test     # run ERT test suite
#   make emacs-format   # indent elisp + prettier on Markdown
#   make emacs-install  # install to $(prefix)/share/emacs/site-lisp/
#   make emacs-clean    # remove byte-compiled artifacts
#
# Override EMACS to select the Emacs binary:
#   make emacs-test EMACS=/path/to/emacs

.PHONY: emacs emacs-test emacs-format emacs-install emacs-clean

# EMACS may be unset in autotools context; default to "emacs".
EMACS ?= emacs

emacs:
	@command -v $(EMACS) >/dev/null 2>&1 || { \
	    echo "emacs not found - install Emacs or set EMACS=<path>" >&2; \
	    exit 1; \
	}
	$(MAKE) -C $(top_srcdir)/emacs all EMACS="$(EMACS)" prefix="$(prefix)"

emacs-test:
	@command -v $(EMACS) >/dev/null 2>&1 || { \
	    echo "emacs not found - install Emacs or set EMACS=<path>" >&2; \
	    exit 1; \
	}
	$(MAKE) -C $(top_srcdir)/emacs test EMACS="$(EMACS)" prefix="$(prefix)"

emacs-format:
	@command -v $(EMACS) >/dev/null 2>&1 || { \
	    echo "emacs not found - install Emacs or set EMACS=<path>" >&2; \
	    exit 1; \
	}
	$(MAKE) -C $(top_srcdir)/emacs format EMACS="$(EMACS)" prefix="$(prefix)"

emacs-install:
	@command -v $(EMACS) >/dev/null 2>&1 || { \
	    echo "emacs not found - install Emacs or set EMACS=<path>" >&2; \
	    exit 1; \
	}
	$(MAKE) -C $(top_srcdir)/emacs install EMACS="$(EMACS)" prefix="$(prefix)"

emacs-clean:
	$(MAKE) -C $(top_srcdir)/emacs clean

# Bear target — produce compile_commands.json for clangd by intercepting
# the build. Cleans first so bear sees every compile invocation.
.PHONY: bear
bear:
	@command -v bear >/dev/null 2>&1 || { \
	    echo "bear not installed - install via your package manager." >&2; \
	    exit 1; \
	}
	$(MAKE) clean
	bear --output $(top_srcdir)/compile_commands.json -- $(MAKE)

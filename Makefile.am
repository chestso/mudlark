# Makefile.am - Top-level automake file for bloom-telnet

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
    TODO.md

# Format target — clang-format on C, shfmt on shell, prettier on Markdown,
# black on Python, and the Lisp formatter (from the installed bloom-lisp
# share dir or sibling checkout) on .lisp files via bloom-repl.
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
	if command -v bloom-repl >/dev/null 2>&1; then repl=bloom-repl; fi; \
	for cand in "$$HOME/.local/share/bloom-lisp/lisp/lisp-fmt.lisp" \
	            "$(top_srcdir)/../bloom-lisp/lisp/lisp-fmt.lisp"; do \
	    [ -f "$$cand" ] && { lisp_fmt="$$cand"; break; }; \
	done; \
	if [ -n "$$repl" ] && [ -n "$$lisp_fmt" ]; then \
	    echo "Formatting Lisp via $$repl ($$lisp_fmt) ..."; \
	    find $(top_srcdir)/lisp -name '*.lisp' -print0 \
	        | xargs -0 -r -n 1 "$$repl" "$$lisp_fmt" -- -i; \
	else \
	    echo "bloom-repl or lisp-fmt.lisp not found - skipping Lisp formatting." >&2; \
	fi

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

# Spell-translator regeneration — re-mines ~/telnet-logs/ and rewrites
# lisp/contrib/spell-translator.lisp from its template. Override the log
# directory with `make spell-translator LOGDIR=/path/to/logs`.
.PHONY: spell-translator
spell-translator:
	$(top_srcdir)/build-aux/spell-translator/build-spell-translator.sh $(LOGDIR)

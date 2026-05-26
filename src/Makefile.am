# src/Makefile.am - Source files for bloom-telnet

# Regenerate bloom_version.h on every `make` so the embedded version string
# tracks the current git HEAD (including a -dirty suffix when the working
# tree has uncommitted changes). The recipe always runs, but the file is
# only rewritten when the version actually changes — so dependent .o files
# stay cached when nothing changed.
BUILT_SOURCES = bloom_version.h
CLEANFILES = bloom_version.h

.PHONY: bloom_version_force
bloom_version.h: bloom_version_force
	@v=`"$(top_srcdir)/build-aux/git-version.sh" "$(top_srcdir)" 2>/dev/null`; \
	test -n "$$v" || v="$(BLOOM_TELNET_VERSION)"; \
	test -n "$$v" || v="unknown"; \
	printf '#ifndef BLOOM_VERSION_H\n#define BLOOM_VERSION_H\n#define BLOOM_TELNET_VERSION "%s"\n#endif\n' "$$v" > $@.tmp; \
	if cmp -s $@.tmp $@ 2>/dev/null; then \
	  rm -f $@.tmp; \
	else \
	  mv $@.tmp $@; \
	  echo "  GEN      $@ ($$v)"; \
	fi
bloom_version_force:

bin_PROGRAMS = bloom-telnet

bloom_telnet_SOURCES = \
    main.c \
    telnet.c \
    path_utils.c \
    path_utils.h \
    session.c \
    session.h \
    lisp_extension.c \
    lisp_extension.h \
    logging.c \
    logging.h \
    commands.c \
    commands.h \
    terminal_caps.c \
    telnet_app.c \
    telnet_app.h

bloom_telnet_CPPFLAGS = \
    -I$(top_srcdir)/include \
    $(BLOOMBOBA_CFLAGS) \
    $(BLOOMLISP_CFLAGS)

bloom_telnet_LDADD = \
    $(BLOOMBOBA_LIBS) \
    $(BLOOMLISP_LIBS) \
    $(SOCKET_LIBS)

# src/Makefile.am - Source files for mudlark

# Regenerate bloom_version.h on every `make` so the embedded version string
# tracks the current git HEAD (including a -dirty suffix when the working
# tree has uncommitted changes). The recipe always runs, but the file is
# only rewritten when the version actually changes — so dependent .o files
# stay cached when nothing changed.
BUILT_SOURCES = mudlark_version.h
CLEANFILES = mudlark_version.h

.PHONY: mudlark_version_force
mudlark_version.h: mudlark_version_force
	@v=`"$(top_srcdir)/build-aux/git-version.sh" "$(top_srcdir)" 2>/dev/null`; \
	test -n "$$v" || v="$(MUDLARK_VERSION)"; \
	test -n "$$v" || v="unknown"; \
	printf '#ifndef MUDLARK_VERSION_H\n#define MUDLARK_VERSION_H\n#define MUDLARK_VERSION "%s"\n#endif\n' "$$v" > $@.tmp; \
	if cmp -s $@.tmp $@ 2>/dev/null; then \
	  rm -f $@.tmp; \
	else \
	  mv $@.tmp $@; \
	  echo "  GEN      $@ ($$v)"; \
	fi
mudlark_version_force:

bin_PROGRAMS = mudlark

mudlark_SOURCES = \
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

mudlark_CPPFLAGS = \
    -I$(top_srcdir)/include \
    $(BLOOMBOBA_CFLAGS) \
    $(BLOOMLISP_CFLAGS)

mudlark_LDADD = \
    $(BLOOMBOBA_LIBS) \
    $(BLOOMLISP_LIBS) \
    $(SOCKET_LIBS)

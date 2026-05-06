# tests/Makefile.am - Test files

# C tests
check_PROGRAMS = test_telnet_app test_event_loop test_add_hook_fixnum test_telnet_connect_fixnum

test_telnet_app_SOURCES = test_telnet_app.c
test_telnet_app_CPPFLAGS = \
    -I$(top_srcdir)/src \
    -I$(top_srcdir)/include \
    $(BLOOMBOBA_CFLAGS)
test_telnet_app_LDADD = \
    $(top_builddir)/src/bloom_telnet-telnet_app.o \
    $(BLOOMBOBA_LIBS)

test_event_loop_SOURCES = test_event_loop.c
test_event_loop_CPPFLAGS = \
    -I$(top_srcdir)/src \
    -I$(top_srcdir)/include \
    $(BLOOMBOBA_CFLAGS)
test_event_loop_LDADD = \
    $(top_builddir)/src/bloom_telnet-telnet.o \
    $(top_builddir)/src/bloom_telnet-logging.o \
    $(top_builddir)/src/bloom_telnet-path_utils.o \
    $(BLOOMLISP_LIBS) \
    $(BLOOMBOBA_LIBS)

test_add_hook_fixnum_SOURCES = test_add_hook_fixnum.c
test_add_hook_fixnum_CPPFLAGS = \
    -I$(top_srcdir)/src \
    -I$(top_srcdir)/include \
    $(BLOOMBOBA_CFLAGS)
test_add_hook_fixnum_LDADD = \
    $(top_builddir)/src/bloom_telnet-lisp_extension.o \
    $(top_builddir)/src/bloom_telnet-session.o \
    $(top_builddir)/src/bloom_telnet-telnet.o \
    $(top_builddir)/src/bloom_telnet-logging.o \
    $(top_builddir)/src/bloom_telnet-path_utils.o \
    $(top_builddir)/src/bloom_telnet-terminal_caps.o \
    $(BLOOMLISP_LIBS) \
    $(BLOOMBOBA_LIBS)

test_telnet_connect_fixnum_SOURCES = test_telnet_connect_fixnum.c
test_telnet_connect_fixnum_CPPFLAGS = \
    -I$(top_srcdir)/src \
    -I$(top_srcdir)/include \
    $(BLOOMBOBA_CFLAGS)
test_telnet_connect_fixnum_LDADD = \
    $(top_builddir)/src/bloom_telnet-lisp_extension.o \
    $(top_builddir)/src/bloom_telnet-session.o \
    $(top_builddir)/src/bloom_telnet-telnet.o \
    $(top_builddir)/src/bloom_telnet-logging.o \
    $(top_builddir)/src/bloom_telnet-path_utils.o \
    $(top_builddir)/src/bloom_telnet-terminal_caps.o \
    $(BLOOMLISP_LIBS) \
    $(BLOOMBOBA_LIBS)

# Lisp tests
TESTS = \
    test_telnet_app \
    test_event_loop \
    test_add_hook_fixnum \
    test_telnet_connect_fixnum \
    hooks.lisp \
    slash-commands.lisp \
    tintin-colors.lisp \
    tintin-commands.lisp \
    tintin-patterns.lisp \
    tintin-parsing.lisp \
    tintin-highlights.lisp \
    tintin-speedwalk.lisp \
    tintin-alias-ordering.lisp \
    tintin-alias-echo.lisp \
    tintin-action-depth.lisp \
    test-case-completion.lisp \
    test_test_server.py

TEST_EXTENSIONS = .lisp .py
LISP_LOG_COMPILER = $(srcdir)/run-test.sh
PY_LOG_COMPILER = python3

AM_TESTS_ENVIRONMENT = \
    BLOOM_REPL="$${BLOOM_REPL:-bloom-repl}"; \
    export BLOOM_REPL;

EXTRA_DIST = \
    run-test.sh \
    run-bench.sh \
    test-helpers.lisp \
    test-loader.lisp \
    bench-completion.lisp \
    bench-trie-insert.lisp \
    hooks.lisp \
    slash-commands.lisp \
    tintin-colors.lisp \
    tintin-commands.lisp \
    tintin-patterns.lisp \
    tintin-parsing.lisp \
    tintin-highlights.lisp \
    tintin-speedwalk.lisp \
    tintin-alias-ordering.lisp \
    tintin-alias-echo.lisp \
    tintin-action-depth.lisp \
    test-case-completion.lisp \
    test_test_server.py

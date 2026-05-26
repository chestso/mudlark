dnl configure.ac - Autoconf configuration for bloom-telnet
dnl Process this file with autoconf to produce a configure script.

AC_PREREQ([2.69])
AC_INIT([bloom-telnet],
        m4_esyscmd_s([cat version 2>/dev/null || echo "0.0.0-unknown"]),
        [thomasc1971@hotmail.com])
AC_CONFIG_SRCDIR([src/telnet.c])
AC_CONFIG_HEADERS([config.h])
AC_CONFIG_AUX_DIR([build-aux])
AC_CONFIG_MACRO_DIR([m4])
AC_CANONICAL_HOST

AM_INIT_AUTOMAKE([1.14 foreign subdir-objects -Wall -Werror])
AM_SILENT_RULES([yes])

dnl Recompute the version at configure time so a rebuild after new commits
dnl picks up the current version without needing to re-run autoreconf. Falls
dnl back to PACKAGE_VERSION (set at autoreconf time via m4_esyscmd_s above)
dnl for tarball builds where build-aux/git-version.sh has nothing to read.
BLOOM_TELNET_VERSION=`"$srcdir/build-aux/git-version.sh" "$srcdir" 2>/dev/null`
AS_IF([test -z "$BLOOM_TELNET_VERSION"],
      [BLOOM_TELNET_VERSION="$PACKAGE_VERSION"])
AC_SUBST([BLOOM_TELNET_VERSION])
AC_MSG_NOTICE([bloom-telnet version: $BLOOM_TELNET_VERSION])
dnl BLOOM_TELNET_VERSION is exposed to source via the compile-time-generated
dnl bloom_version.h (see src/Makefile.am), not via config.h.

dnl Check for programs
AC_PROG_CC
AC_PROG_RANLIB
AM_PROG_AR

dnl Debug option
AC_ARG_ENABLE([debug],
  [AS_HELP_STRING([--enable-debug],
    [enable debug symbols and disable optimizations])],
  [enable_debug=$enableval],
  [enable_debug=no])

if test "x$enable_debug" = "xyes"; then
  CFLAGS="-O0 -g3 -DDEBUG $CFLAGS"
  AC_MSG_NOTICE([Debug mode enabled: CFLAGS set to -O0 -g3 -DDEBUG])
else
  if test "x$CFLAGS" = "x"; then
    CFLAGS="-O2"
  fi
fi

dnl Check for pkg-config
PKG_PROG_PKG_CONFIG

dnl Check for bloom-lisp
PKG_CHECK_MODULES([BLOOMLISP], [bloom-lisp])

dnl Check for bloom-boba
PKG_CHECK_MODULES([BLOOMBOBA], [bloom-boba])

dnl Platform-specific socket libraries
case "$host_os" in
    mingw*|msys*)
        SOCKET_LIBS="-lws2_32"
        ;;
    *)
        SOCKET_LIBS=""
        ;;
esac
AC_SUBST([SOCKET_LIBS])

dnl Check for header files
AC_CHECK_HEADERS([stdlib.h string.h unistd.h termios.h sys/ioctl.h sys/select.h arpa/inet.h netdb.h])

dnl Check for typedefs and structures
AC_TYPE_SIZE_T
AC_TYPE_SSIZE_T

dnl Check for library functions
AC_CHECK_FUNCS([memset socket select getaddrinfo])

dnl Output files
AC_CONFIG_FILES([
    Makefile
    include/Makefile
    src/Makefile
    lisp/Makefile
    tests/Makefile
])

AC_OUTPUT

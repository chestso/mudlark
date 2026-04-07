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

AM_INIT_AUTOMAKE([foreign subdir-objects -Wall -Werror])

dnl Check for programs
AC_PROG_CC
AC_PROG_RANLIB
AM_PROG_AR

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

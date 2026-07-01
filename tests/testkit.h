/* testkit.h - Reusable C test infrastructure for mudlark
 *
 * Provides:
 * - Noop TUI component for creating test runtimes
 * - Socketpair-based Telnet for capturing sent data
 * - Stubs for common linked dependencies
 * - Test runner macros
 */

#ifndef MUDLARK_TESTKIT_H
#define MUDLARK_TESTKIT_H

#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <io.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#define DEVNULL "NUL"

static void testkit_wsa_startup(void)
{
    static int wsa_initialized = 0;
    if (!wsa_initialized) {
        WSADATA d;
        WSAStartup(MAKEWORD(2, 2), &d);
        wsa_initialized = 1;
    }
}
#else
#include <sys/socket.h>
#include <unistd.h>
#define DEVNULL "/dev/null"
#endif

#include <boba/cmd.h>
#include <boba/component.h>
#include <boba/dynamic_buffer.h>
#include <boba/msg.h>
#include <boba/runtime.h>

#include "../include/telnet.h"
#include "../src/telnet_internal.h"

/* ========================================================================
 * Test runner
 * ======================================================================== */

static int testkit_tests_run = 0;
static int testkit_tests_passed = 0;

#define RUN_TEST(fn)                 \
    do {                             \
        testkit_tests_run++;         \
        fn();                        \
        testkit_tests_passed++;      \
        printf("  PASS: %s\n", #fn); \
    } while (0)

#define TEST_SUMMARY()                                              \
    do {                                                            \
        printf("\n%d/%d tests passed.\n", testkit_tests_passed,     \
               testkit_tests_run);                                  \
        return (testkit_tests_passed == testkit_tests_run) ? 0 : 1; \
    } while (0)

/* ========================================================================
 * Noop component — minimal Elm Architecture component for test runtimes
 * ======================================================================== */

static TuiModel testkit_noop_model;

static TuiInitResult testkit_noop_init(void *config)
{
    (void)config;
    testkit_noop_model.type = 0;
    return tui_init_result_none(&testkit_noop_model);
}

static TuiUpdateResult testkit_noop_update(TuiModel *model, TuiMsg msg)
{
    (void)model;
    (void)msg;
    return tui_update_result_none();
}

static TuiView testkit_noop_view(const TuiModel *model, DynamicBuffer *out)
{
    (void)model;
    return tui_view_default(out);
}

static void testkit_noop_free(TuiModel *model) { (void)model; }

static TuiComponent testkit_noop_component = {
    .init = testkit_noop_init,
    .update = testkit_noop_update,
    .view = testkit_noop_view,
    .free = testkit_noop_free,
};

/* ========================================================================
 * Runtime helpers
 * ======================================================================== */

/* Create a test runtime with noop component and /dev/null output */
static TuiRuntime *testkit_create_runtime(void)
{
    FILE *devnull = fopen(DEVNULL, "w");
    assert(devnull != NULL);

    TuiRuntimeConfig cfg = { .output = devnull };
    TuiRuntime *rt =
        tui_runtime_create(&testkit_noop_component, NULL, &cfg);
    assert(rt != NULL);
    return rt;
}

/* Free a test runtime (also closes /dev/null output) */
static void testkit_free_runtime(TuiRuntime *rt)
{
    FILE *output = rt->output;
    tui_runtime_free(rt);
    if (output)
        fclose(output);
}

/* ========================================================================
 * Telnet helpers — socketpair-based Telnet for capturing sent data
 * ======================================================================== */

/* Create a socketpair: returns the "capture" fd, sets *telnet_fd to the other.
 * The capture fd is set non-blocking for reading. */
#ifdef _WIN32
static int testkit_create_socketpair(int *telnet_fd)
{
    testkit_wsa_startup();
    SOCKET listen_sd = socket(AF_INET, SOCK_STREAM, 0);
    assert(listen_sd != INVALID_SOCKET);

    struct sockaddr_in addr = { 0 };
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0; /* auto-assign */
    int ret = bind(listen_sd, (struct sockaddr *)&addr, sizeof(addr));
    assert(ret == 0);

    socklen_t addrlen = sizeof(addr);
    getsockname(listen_sd, (struct sockaddr *)&addr, &addrlen);
    listen(listen_sd, 1);

    SOCKET client_sd = socket(AF_INET, SOCK_STREAM, 0);
    assert(client_sd != INVALID_SOCKET);
    connect(client_sd, (struct sockaddr *)&addr, sizeof(addr));

    SOCKET server_sd = accept(listen_sd, NULL, NULL);
    assert(server_sd != INVALID_SOCKET);
    closesocket(listen_sd);

    u_long mode = 1;
    ioctlsocket(server_sd, FIONBIO, &mode);

    *telnet_fd = (int)client_sd;
    return (int)server_sd; /* capture fd */
}
#else
static int testkit_create_socketpair(int *telnet_fd)
{
    int fds[2];
    int ret = socketpair(AF_UNIX, SOCK_STREAM, 0, fds);
    assert(ret == 0);

    /* Set capture end to non-blocking */
    int flags = fcntl(fds[0], F_GETFL, 0);
    fcntl(fds[0], F_SETFL, flags | O_NONBLOCK);

    *telnet_fd = fds[1];
    return fds[0]; /* capture fd */
}
#endif

/* Create a Telnet connected to a socketpair.
 * Returns the Telnet; sets *capture_fd to the readable end. */
static Telnet *testkit_create_telnet(int *capture_fd)
{
    int telnet_fd;
    *capture_fd = testkit_create_socketpair(&telnet_fd);

    Telnet *t = telnet_create();
    assert(t != NULL);
    t->socket = telnet_fd;
    t->state = TELNET_STATE_CONNECTED;
    return t;
}

/* Read all available data from a non-blocking fd into a buffer.
 * Returns number of bytes read. */
static int testkit_recv_all(int fd, char *buf, int bufsize)
{
    int total = 0;
    while (total < bufsize - 1) {
#ifdef _WIN32
        int n = recv(fd, buf + total, bufsize - 1 - total, 0);
        if (n <= 0) {
            WSAGetLastError();
            break;
        }
#else
        int n = read(fd, buf + total, bufsize - 1 - total);
        if (n <= 0)
            break;
#endif
        total += n;
    }
    buf[total] = '\0';
    return total;
}

/* ========================================================================
 * Common stubs — for symbols needed by telnet.o and logging.o
 *
 * Only define these if the test doesn't link the real implementations.
 * Guard with TESTKIT_STUB_* macros so tests can opt out.
 * ======================================================================== */

#ifndef TESTKIT_NO_STUB_LISP
void *lisp_x_get_environment(void) { return NULL; }
int lisp_x_get_color(const char *n, int *r, int *g, int *b)
{
    (void)n;
    (void)r;
    (void)g;
    (void)b;
    return -1;
}
#endif

#ifndef TESTKIT_NO_STUB_TERMCAPS
const char *termcaps_format_reset(void) { return ""; }
const char *termcaps_format_fg_color(int r, int g, int b)
{
    (void)r;
    (void)g;
    (void)b;
    return "";
}
#endif

#endif /* MUDLARK_TESTKIT_H */

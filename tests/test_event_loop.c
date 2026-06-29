/* test_event_loop.c - Tests for C-level event loop behaviors
 *
 * Verifies that side effects (telnet sends, etc.) are properly routed
 * through the boba event loop rather than executed directly.
 */

#include "testkit.h"

/* ========================================================================
 * Tests: DynamicBuffer \0-separated accumulation pattern
 *
 * This tests the buffer protocol used by telnet-send: multiple strings
 * appended with \0 separators, then iterated in order.
 * ======================================================================== */

static void test_buffer_single_entry(void)
{
    DynamicBuffer *buf = dynamic_buffer_create(256);

    dynamic_buffer_append(buf, "hello", 5);
    dynamic_buffer_append(buf, "\0", 1);

    assert(dynamic_buffer_len(buf) == 6);

    const char *p = dynamic_buffer_data(buf);
    assert(strcmp(p, "hello") == 0);

    dynamic_buffer_destroy(buf);
}

static void test_buffer_multiple_entries(void)
{
    DynamicBuffer *buf = dynamic_buffer_create(256);

    dynamic_buffer_append(buf, "north", 5);
    dynamic_buffer_append(buf, "\0", 1);
    dynamic_buffer_append(buf, "look", 4);
    dynamic_buffer_append(buf, "\0", 1);
    dynamic_buffer_append(buf, "south", 5);
    dynamic_buffer_append(buf, "\0", 1);

    const char *p = dynamic_buffer_data(buf);
    const char *end = p + dynamic_buffer_len(buf);

    assert(strcmp(p, "north") == 0);
    p += strlen(p) + 1;
    assert(p < end);

    assert(strcmp(p, "look") == 0);
    p += strlen(p) + 1;
    assert(p < end);

    assert(strcmp(p, "south") == 0);
    p += strlen(p) + 1;
    assert(p == end);

    dynamic_buffer_destroy(buf);
}

static void test_buffer_empty_strings(void)
{
    DynamicBuffer *buf = dynamic_buffer_create(256);

    /* Empty string is valid (sends just CRLF) */
    dynamic_buffer_append(buf, "", 0);
    dynamic_buffer_append(buf, "\0", 1);
    dynamic_buffer_append(buf, "look", 4);
    dynamic_buffer_append(buf, "\0", 1);

    const char *p = dynamic_buffer_data(buf);
    const char *end = p + dynamic_buffer_len(buf);

    assert(strcmp(p, "") == 0);
    p += strlen(p) + 1;
    assert(p < end);

    assert(strcmp(p, "look") == 0);
    p += strlen(p) + 1;
    assert(p == end);

    dynamic_buffer_destroy(buf);
}

static void test_buffer_clear_resets(void)
{
    DynamicBuffer *buf = dynamic_buffer_create(256);

    dynamic_buffer_append(buf, "data", 4);
    dynamic_buffer_append(buf, "\0", 1);
    assert(dynamic_buffer_len(buf) == 5);

    dynamic_buffer_clear(buf);
    assert(dynamic_buffer_len(buf) == 0);

    /* Buffer is reusable after clear */
    dynamic_buffer_append(buf, "new", 3);
    dynamic_buffer_append(buf, "\0", 1);
    assert(dynamic_buffer_len(buf) == 4);
    assert(strcmp(dynamic_buffer_data(buf), "new") == 0);

    dynamic_buffer_destroy(buf);
}

/* ========================================================================
 * Tests: Runtime schedule + drain
 *
 * Verifies that tui_cmd_custom callbacks execute only when the runtime
 * is drained, not when scheduled.
 * ======================================================================== */

static int callback_call_count = 0;
static char callback_received[256] = "";

static TuiMsg capture_callback(void *data)
{
    callback_call_count++;
    if (data) {
        strncpy(callback_received, (const char *)data, sizeof(callback_received));
        callback_received[sizeof(callback_received) - 1] = '\0';
    }
    return tui_msg_none();
}

static void test_schedule_does_not_execute_immediately(void)
{
    TuiRuntime *rt = testkit_create_runtime();

    callback_call_count = 0;
    tui_runtime_schedule(rt, tui_cmd_custom(capture_callback, NULL, NULL));

    assert(callback_call_count == 0); /* Not called yet */

    testkit_free_runtime(rt);
}

static void test_drain_executes_scheduled_commands(void)
{
    TuiRuntime *rt = testkit_create_runtime();

    callback_call_count = 0;
    tui_runtime_schedule(rt, tui_cmd_custom(capture_callback, NULL, NULL));

    tui_runtime_drain(rt);
    assert(callback_call_count == 1); /* Called after drain */

    testkit_free_runtime(rt);
}

static int order_buf[3];
static int order_idx = 0;

static TuiMsg order_cb1(void *d)
{
    (void)d;
    order_buf[order_idx++] = 1;
    return tui_msg_none();
}
static TuiMsg order_cb2(void *d)
{
    (void)d;
    order_buf[order_idx++] = 2;
    return tui_msg_none();
}
static TuiMsg order_cb3(void *d)
{
    (void)d;
    order_buf[order_idx++] = 3;
    return tui_msg_none();
}

static void test_drain_executes_multiple_in_order(void)
{
    TuiRuntime *rt = testkit_create_runtime();
    order_idx = 0;

    tui_runtime_schedule(rt, tui_cmd_custom(order_cb1, NULL, NULL));
    tui_runtime_schedule(rt, tui_cmd_custom(order_cb2, NULL, NULL));
    tui_runtime_schedule(rt, tui_cmd_custom(order_cb3, NULL, NULL));

    tui_runtime_drain(rt);

    assert(order_idx == 3);
    assert(order_buf[0] == 1);
    assert(order_buf[1] == 2);
    assert(order_buf[2] == 3);

    testkit_free_runtime(rt);
}

static void test_callback_receives_data(void)
{
    TuiRuntime *rt = testkit_create_runtime();

    callback_call_count = 0;
    memset(callback_received, 0, sizeof(callback_received));

    char *text = strdup("hello world");
    tui_runtime_schedule(rt, tui_cmd_custom(capture_callback, text, free));

    tui_runtime_drain(rt);

    assert(callback_call_count == 1);
    assert(strcmp(callback_received, "hello world") == 0);

    testkit_free_runtime(rt);
}

/* ========================================================================
 * Tests: Telnet send via socketpair
 *
 * Verifies that telnet_send_with_crlf delivers data through a socket,
 * which we capture via a socketpair.
 * ======================================================================== */

static void test_telnet_send_via_socketpair(void)
{
    int capture_fd;
    Telnet *t = testkit_create_telnet(&capture_fd);

    telnet_send_with_crlf(t, "look", 4);

    char buf[256];
    int n = testkit_recv_all(capture_fd, buf, sizeof(buf));

    assert(n == 6); /* "look" + "\r\n" */
    assert(memcmp(buf, "look\r\n", 6) == 0);

    telnet_destroy(t);
    close(capture_fd);
}

static void test_telnet_send_multiple_via_socketpair(void)
{
    int capture_fd;
    Telnet *t = testkit_create_telnet(&capture_fd);

    telnet_send_with_crlf(t, "north", 5);
    telnet_send_with_crlf(t, "look", 4);

    char buf[256];
    int n = testkit_recv_all(capture_fd, buf, sizeof(buf));

    assert(n == 13); /* "north\r\n" + "look\r\n" */
    assert(memcmp(buf, "north\r\nlook\r\n", 13) == 0);

    telnet_destroy(t);
    close(capture_fd);
}

/* ========================================================================
 * Tests: Full event loop path — schedule callback that sends to telnet
 *
 * Simulates the telnet-send flow: callback is scheduled, drain executes
 * it, and data arrives on the socketpair.
 * ======================================================================== */

/* Test context for send callback */
typedef struct
{
    DynamicBuffer *buf;
    Telnet *telnet;
} SendContext;

/* Callback that mimics flush_pending_sends */
static TuiMsg test_flush_callback(void *data)
{
    SendContext *ctx = (SendContext *)data;
    const char *p = dynamic_buffer_data(ctx->buf);
    const char *end = p + dynamic_buffer_len(ctx->buf);
    while (p < end) {
        size_t len = strlen(p);
        telnet_send_with_crlf(ctx->telnet, p, len);
        p += len + 1;
    }
    dynamic_buffer_clear(ctx->buf);
    return tui_msg_none();
}

static void test_event_loop_send_single(void)
{
    TuiRuntime *rt = testkit_create_runtime();
    int capture_fd;
    Telnet *t = testkit_create_telnet(&capture_fd);

    DynamicBuffer *buf = dynamic_buffer_create(256);
    dynamic_buffer_append(buf, "look", 4);
    dynamic_buffer_append(buf, "\0", 1);

    SendContext ctx = { .buf = buf, .telnet = t };
    tui_runtime_schedule(rt, tui_cmd_custom(test_flush_callback, &ctx, NULL));

    /* Nothing sent yet */
    char recv_buf[256];
    int n = testkit_recv_all(capture_fd, recv_buf, sizeof(recv_buf));
    assert(n == 0);

    /* Drain executes the callback */
    tui_runtime_drain(rt);

    n = testkit_recv_all(capture_fd, recv_buf, sizeof(recv_buf));
    assert(n == 6);
    assert(memcmp(recv_buf, "look\r\n", 6) == 0);
    assert(dynamic_buffer_len(buf) == 0); /* Buffer cleared */

    dynamic_buffer_destroy(buf);
    telnet_destroy(t);
    close(capture_fd);
    testkit_free_runtime(rt);
}

static void test_event_loop_send_multiple_batched(void)
{
    TuiRuntime *rt = testkit_create_runtime();
    int capture_fd;
    Telnet *t = testkit_create_telnet(&capture_fd);

    DynamicBuffer *buf = dynamic_buffer_create(256);

    /* Simulate multiple telnet-send calls accumulating in buffer */
    dynamic_buffer_append(buf, "north", 5);
    dynamic_buffer_append(buf, "\0", 1);
    dynamic_buffer_append(buf, "look", 4);
    dynamic_buffer_append(buf, "\0", 1);
    dynamic_buffer_append(buf, "south", 5);
    dynamic_buffer_append(buf, "\0", 1);

    SendContext ctx = { .buf = buf, .telnet = t };
    tui_runtime_schedule(rt, tui_cmd_custom(test_flush_callback, &ctx, NULL));

    /* Nothing sent yet */
    char recv_buf[256];
    int n = testkit_recv_all(capture_fd, recv_buf, sizeof(recv_buf));
    assert(n == 0);

    /* Drain sends all three */
    tui_runtime_drain(rt);

    n = testkit_recv_all(capture_fd, recv_buf, sizeof(recv_buf));
    assert(n == 20); /* "north\r\n" + "look\r\n" + "south\r\n" */
    assert(memcmp(recv_buf, "north\r\nlook\r\nsouth\r\n", 20) == 0);
    assert(dynamic_buffer_len(buf) == 0);

    dynamic_buffer_destroy(buf);
    telnet_destroy(t);
    close(capture_fd);
    testkit_free_runtime(rt);
}

static void test_event_loop_send_ordering(void)
{
    TuiRuntime *rt = testkit_create_runtime();
    int capture_fd;
    Telnet *t = testkit_create_telnet(&capture_fd);

    DynamicBuffer *buf = dynamic_buffer_create(256);

    /* Queue with specific order */
    const char *cmds[] = { "buy seaweed", "put 1. girdle", "look" };
    for (int i = 0; i < 3; i++) {
        dynamic_buffer_append(buf, cmds[i], strlen(cmds[i]));
        dynamic_buffer_append(buf, "\0", 1);
    }

    SendContext ctx = { .buf = buf, .telnet = t };
    tui_runtime_schedule(rt, tui_cmd_custom(test_flush_callback, &ctx, NULL));
    tui_runtime_drain(rt);

    char recv_buf[256];
    int n = testkit_recv_all(capture_fd, recv_buf, sizeof(recv_buf));

    /* Verify order is preserved */
    assert(n > 0);
    assert(strstr(recv_buf, "buy seaweed\r\nput 1. girdle\r\nlook\r\n") ==
           recv_buf);

    dynamic_buffer_destroy(buf);
    telnet_destroy(t);
    close(capture_fd);
    testkit_free_runtime(rt);
}

static void test_event_loop_buffer_reusable_after_flush(void)
{
    TuiRuntime *rt = testkit_create_runtime();
    int capture_fd;
    Telnet *t = testkit_create_telnet(&capture_fd);

    DynamicBuffer *buf = dynamic_buffer_create(256);
    SendContext ctx = { .buf = buf, .telnet = t };

    /* First batch */
    dynamic_buffer_append(buf, "look", 4);
    dynamic_buffer_append(buf, "\0", 1);
    tui_runtime_schedule(rt, tui_cmd_custom(test_flush_callback, &ctx, NULL));
    tui_runtime_drain(rt);

    char recv_buf[256];
    int n = testkit_recv_all(capture_fd, recv_buf, sizeof(recv_buf));
    assert(n == 6);
    assert(memcmp(recv_buf, "look\r\n", 6) == 0);

    /* Second batch reuses the same buffer */
    dynamic_buffer_append(buf, "north", 5);
    dynamic_buffer_append(buf, "\0", 1);
    tui_runtime_schedule(rt, tui_cmd_custom(test_flush_callback, &ctx, NULL));
    tui_runtime_drain(rt);

    n = testkit_recv_all(capture_fd, recv_buf, sizeof(recv_buf));
    assert(n == 7);
    assert(memcmp(recv_buf, "north\r\n", 7) == 0);

    dynamic_buffer_destroy(buf);
    telnet_destroy(t);
    close(capture_fd);
    testkit_free_runtime(rt);
}

/* ======================================================================== */

int main(void)
{
    printf("event loop tests:\n");

    /* Buffer accumulation pattern */
    printf("\n  Buffer accumulation:\n");
    RUN_TEST(test_buffer_single_entry);
    RUN_TEST(test_buffer_multiple_entries);
    RUN_TEST(test_buffer_empty_strings);
    RUN_TEST(test_buffer_clear_resets);

    /* Runtime schedule + drain */
    printf("\n  Runtime schedule/drain:\n");
    RUN_TEST(test_schedule_does_not_execute_immediately);
    RUN_TEST(test_drain_executes_scheduled_commands);
    RUN_TEST(test_drain_executes_multiple_in_order);
    RUN_TEST(test_callback_receives_data);

    /* Telnet send via socketpair */
    printf("\n  Telnet socketpair send:\n");
    RUN_TEST(test_telnet_send_via_socketpair);
    RUN_TEST(test_telnet_send_multiple_via_socketpair);

    /* Full event loop path */
    printf("\n  Event loop integration:\n");
    RUN_TEST(test_event_loop_send_single);
    RUN_TEST(test_event_loop_send_multiple_batched);
    RUN_TEST(test_event_loop_send_ordering);
    RUN_TEST(test_event_loop_buffer_reusable_after_flush);

    TEST_SUMMARY();
}

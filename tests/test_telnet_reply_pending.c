/* test_telnet_reply_pending.c - The telnet layer owns "an answer is owed"
 *
 * The frame keeps the row the server's answer will land in free while the
 * server owes an answer. The fact itself belongs to the telnet layer: the
 * line-sending path sets it, the first byte that arrives clears it, and a
 * disconnect clears it too. main.c only mirrors it into the frame.
 *
 * The protocol traffic (IAC negotiation, NAWS) is not a user line and must
 * never reserve a row.
 */

#include "testkit.h"

/* A line that reached the server starts an answer being owed. */
static void test_send_with_crlf_awaits_a_reply(void)
{
    int capture_fd;
    Telnet *t = testkit_create_telnet(&capture_fd);

    assert(telnet_awaiting_reply(t) == 0);

    telnet_send_with_crlf(t, "look", 4);

    assert(telnet_awaiting_reply(t) == 1);

    telnet_destroy(t);
    close(capture_fd);
}

/* The first byte that arrives is the answer: the reservation is dropped. */
static void test_receive_clears_the_pending_reply(void)
{
    int capture_fd;
    Telnet *t = testkit_create_telnet(&capture_fd);

    telnet_send_with_crlf(t, "look", 4);
    assert(telnet_awaiting_reply(t) == 1);

    const char *answer = "A dusty path.\r\n";
    size_t answer_len = strlen(answer);
    int sent = send(capture_fd, answer, (int)answer_len, 0);
    assert(sent == (int)answer_len);

    char buf[256];
    int received = telnet_receive(t, buf, sizeof(buf) - 1);
    assert(received == (int)answer_len);
    assert(memcmp(buf, answer, answer_len) == 0);

    /* The answer arrived: the frame gives the reserved row back. */
    assert(telnet_awaiting_reply(t) == 0);

    telnet_destroy(t);
    close(capture_fd);
}

/* A disconnect ends the wait: no answer can come any more. */
static void test_disconnect_clears_the_pending_reply(void)
{
    int capture_fd;
    Telnet *t = testkit_create_telnet(&capture_fd);

    telnet_send_with_crlf(t, "look", 4);
    assert(telnet_awaiting_reply(t) == 1);

    telnet_disconnect(t);

    assert(telnet_awaiting_reply(t) == 0);

    telnet_destroy(t);
    close(capture_fd);
}

/* Protocol traffic is not a user line: it never reserves a row. */
static void test_protocol_traffic_does_not_await_a_reply(void)
{
    int capture_fd;
    Telnet *t = testkit_create_telnet(&capture_fd);

    /* IAC negotiation (the connect-time options). */
    telnet_send_command(telnet_get_socket(t), TELNET_WILL, TELNET_OPT_ECHO);
    assert(telnet_awaiting_reply(t) == 0);

    /* A raw send (no line ending): still not a user line. */
    telnet_send(t, "raw", 3);
    assert(telnet_awaiting_reply(t) == 0);

    /* NAWS (the window size): also not a user line. */
    telnet_set_terminal_size(t, 80, 24);
    assert(telnet_awaiting_reply(t) == 0);

    telnet_destroy(t);
    close(capture_fd);
}

/* A send that never reaches the socket reserves nothing: there is no line
 * on the wire, so the server owes no answer. */
static void test_failed_send_does_not_await_a_reply(void)
{
    int capture_fd;
    Telnet *t = testkit_create_telnet(&capture_fd);

    /* No socket: the send fails before it writes anything. */
    telnet_disconnect(t);

    int sent = telnet_send_with_crlf(t, "look", 4);
    assert(sent < 0);
    assert(telnet_awaiting_reply(t) == 0);

    telnet_destroy(t);
    close(capture_fd);
}

/* ======================================================================== */

int main(void)
{
    printf("telnet reply-pending tests:\n");

    printf("\n  The answer that is owed:\n");
    RUN_TEST(test_send_with_crlf_awaits_a_reply);
    RUN_TEST(test_receive_clears_the_pending_reply);
    RUN_TEST(test_disconnect_clears_the_pending_reply);
    RUN_TEST(test_protocol_traffic_does_not_await_a_reply);
    RUN_TEST(test_failed_send_does_not_await_a_reply);

    TEST_SUMMARY();
}

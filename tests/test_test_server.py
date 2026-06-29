#!/usr/bin/env python3
"""Unit tests for the mudlark test server."""

import os
import sys
import unittest
from unittest.mock import MagicMock, call

# Add tests/ to path so we can import test_server
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from test_server import (
    IAC,
    WILL,
    WONT,
    DO,
    DONT,
    SB,
    SE,
    OPT_ECHO,
    OPT_SGA,
    OPT_NAWS,
    PROMPT,
    TelnetConnection,
    TestServer,
)


def make_connection(server=None):
    """Create a TelnetConnection with a mock socket."""
    if server is None:
        server = TestServer()
    sock = MagicMock()
    conn = TelnetConnection(sock, ("127.0.0.1", 12345), server)
    # Mark banner as already sent to avoid banner noise in tests
    conn.banner_sent = True
    return conn


class TestIACProtocol(unittest.TestCase):
    """Test IAC sequence processing."""

    def test_strips_iac_sequences(self):
        conn = make_connection()
        # IAC WILL SGA embedded in data
        data = b"hello" + bytes([IAC, WILL, OPT_SGA]) + b"world"
        result = conn.process_data(data)
        self.assertEqual(result, b"helloworld")

    def test_doubled_iac_is_escaped_byte(self):
        conn = make_connection()
        data = b"before" + bytes([IAC, IAC]) + b"after"
        result = conn.process_data(data)
        # Doubled IAC is stripped (escaped 0xFF byte), not passed through
        self.assertEqual(result, b"beforeafter")

    def test_will_supported_option_responds_do(self):
        conn = make_connection()
        data = bytes([IAC, WILL, OPT_SGA])
        conn.process_data(data)
        conn.sock.sendall.assert_called_with(bytes([IAC, DO, OPT_SGA]))

    def test_will_unsupported_option_responds_dont(self):
        conn = make_connection()
        data = bytes([IAC, WILL, OPT_ECHO])
        conn.process_data(data)
        conn.sock.sendall.assert_called_with(bytes([IAC, DONT, OPT_ECHO]))

    def test_do_supported_option_responds_will(self):
        conn = make_connection()
        data = bytes([IAC, DO, OPT_SGA])
        conn.process_data(data)
        conn.sock.sendall.assert_called_with(bytes([IAC, WILL, OPT_SGA]))

    def test_do_unsupported_option_responds_wont(self):
        conn = make_connection()
        data = bytes([IAC, DO, OPT_ECHO])
        conn.process_data(data)
        conn.sock.sendall.assert_called_with(bytes([IAC, WONT, OPT_ECHO]))

    def test_wont_responds_dont(self):
        conn = make_connection()
        data = bytes([IAC, WONT, OPT_SGA])
        conn.process_data(data)
        conn.sock.sendall.assert_called_with(bytes([IAC, DONT, OPT_SGA]))

    def test_dont_responds_wont(self):
        conn = make_connection()
        data = bytes([IAC, DONT, OPT_SGA])
        conn.process_data(data)
        conn.sock.sendall.assert_called_with(bytes([IAC, WONT, OPT_SGA]))

    def test_naws_subnegotiation_parses_width(self):
        conn = make_connection()
        # IAC SB NAWS 0 120 0 40 IAC SE
        data = bytes([IAC, SB, OPT_NAWS, 0, 120, 0, 40, IAC, SE])
        conn.process_data(data)
        self.assertEqual(conn.terminal_width, 120)

    def test_incomplete_iac_at_end(self):
        conn = make_connection()
        # IAC at very end of data — should not crash
        data = b"hello" + bytes([IAC])
        result = conn.process_data(data)
        self.assertEqual(result, b"hello")

    def test_incomplete_will_at_end(self):
        conn = make_connection()
        # IAC WILL but no option byte
        data = b"test" + bytes([IAC, WILL])
        result = conn.process_data(data)
        self.assertEqual(result, b"test")

    def test_plain_data_passes_through(self):
        conn = make_connection()
        data = b"just plain text"
        result = conn.process_data(data)
        self.assertEqual(result, b"just plain text")


class TestLineInput(unittest.TestCase):
    """Test line-oriented input parsing."""

    def test_crlf_delimiter(self):
        server = TestServer()
        conn = make_connection(server)
        conn.handle_data(b"hello\r\n")
        # Should echo "hello" back + CRLF + prompt
        calls = conn.sock.sendall.call_args_list
        self.assertIn(call(b"hello"), calls)

    def test_bare_cr_delimiter(self):
        server = TestServer()
        conn = make_connection(server)
        conn.handle_data(b"hello\r")
        calls = conn.sock.sendall.call_args_list
        self.assertIn(call(b"hello"), calls)

    def test_bare_lf_delimiter(self):
        server = TestServer()
        conn = make_connection(server)
        conn.handle_data(b"hello\n")
        calls = conn.sock.sendall.call_args_list
        self.assertIn(call(b"hello"), calls)

    def test_cr_nul_delimiter(self):
        server = TestServer()
        conn = make_connection(server)
        conn.handle_data(b"hello\r\x00")
        calls = conn.sock.sendall.call_args_list
        self.assertIn(call(b"hello"), calls)

    def test_multiple_lines_in_single_chunk(self):
        server = TestServer()
        conn = make_connection(server)
        conn.handle_data(b"one\r\ntwo\r\n")
        calls = conn.sock.sendall.call_args_list
        self.assertIn(call(b"one"), calls)
        self.assertIn(call(b"two"), calls)

    def test_partial_line_buffered(self):
        server = TestServer()
        conn = make_connection(server)
        conn.handle_data(b"hel")
        # No complete line yet — only data in line_buffer
        self.assertEqual(bytes(conn.line_buffer), b"hel")
        # No echo sent (no sendall calls for data)
        calls = conn.sock.sendall.call_args_list
        data_calls = [c for c in calls if c != call(PROMPT.encode("utf-8"))]
        self.assertEqual(len(data_calls), 0)

    def test_partial_line_completed_in_next_chunk(self):
        server = TestServer()
        conn = make_connection(server)
        conn.handle_data(b"hel")
        conn.handle_data(b"lo\r\n")
        calls = conn.sock.sendall.call_args_list
        self.assertIn(call(b"hello"), calls)

    def test_split_delimiter_across_chunks(self):
        server = TestServer()
        conn = make_connection(server)
        conn.handle_data(b"data\r")
        # CR alone should dispatch the line
        calls = conn.sock.sendall.call_args_list
        self.assertIn(call(b"data"), calls)

    def test_empty_line_dispatched(self):
        server = TestServer()
        conn = make_connection(server)
        conn.handle_data(b"\r\n")
        # Empty input still gets a prompt
        calls = conn.sock.sendall.call_args_list
        self.assertIn(call(PROMPT.encode("utf-8")), calls)

    def test_iac_interleaved_with_data(self):
        server = TestServer()
        conn = make_connection(server)
        data = b"hi" + bytes([IAC, WILL, OPT_SGA]) + b"\r\n"
        conn.handle_data(data)
        calls = conn.sock.sendall.call_args_list
        self.assertIn(call(b"hi"), calls)


class TestCommandDispatch(unittest.TestCase):
    """Test command handling."""

    def test_registered_command_invoked(self):
        server = TestServer()
        handler = MagicMock(return_value="pong")
        server.add_command("ping", handler)
        conn = make_connection(server)
        conn.handle_data(b"ping\r\n")
        handler.assert_called_once()

    def test_registered_command_with_args(self):
        server = TestServer()
        handler = MagicMock(return_value="ok")
        server.add_command("say", handler)
        conn = make_connection(server)
        conn.handle_data(b"say hello world\r\n")
        handler.assert_called_once()
        args_passed = handler.call_args[0][0]
        self.assertEqual(args_passed, "hello world")

    def test_unrecognized_input_echoed(self):
        server = TestServer()
        conn = make_connection(server)
        conn.handle_data(b"foobar\r\n")
        calls = conn.sock.sendall.call_args_list
        self.assertIn(call(b"foobar"), calls)

    def test_response_followed_by_crlf_and_prompt(self):
        server = TestServer()
        conn = make_connection(server)
        conn.handle_data(b"test\r\n")
        calls = conn.sock.sendall.call_args_list
        # Find the echo, then check CRLF and prompt follow
        echo_idx = None
        for i, c in enumerate(calls):
            if c == call(b"test"):
                echo_idx = i
                break
        self.assertIsNotNone(echo_idx, "Echo not found")
        self.assertEqual(calls[echo_idx + 1], call(b"\r\n"))
        self.assertEqual(calls[echo_idx + 2], call(PROMPT.encode("utf-8")))

    def test_empty_input_gets_prompt(self):
        server = TestServer()
        conn = make_connection(server)
        conn.handle_data(b"\r\n")
        calls = conn.sock.sendall.call_args_list
        self.assertIn(call(PROMPT.encode("utf-8")), calls)


class TestAcceptConnection(unittest.TestCase):
    """Test connection setup."""

    def test_only_do_naws_sent_on_connect(self):
        """Verify no proactive WILL SGA — only DO NAWS is sent."""
        server = TestServer()
        server.server_socket = MagicMock()
        mock_sock = MagicMock()
        server.server_socket.accept.return_value = (mock_sock, ("127.0.0.1", 9999))

        server.accept_connection()

        # Collect all sendall calls
        calls = mock_sock.sendall.call_args_list
        sent_bytes = b"".join(c[0][0] for c in calls)

        # Should contain DO NAWS
        self.assertIn(bytes([IAC, DO, OPT_NAWS]), sent_bytes)
        # Should NOT contain WILL SGA
        self.assertNotIn(bytes([IAC, WILL, OPT_SGA]), sent_bytes)


if __name__ == "__main__":
    unittest.main()

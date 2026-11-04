#!/usr/bin/env bash
# tmux-driven test for Ctrl+D (delete-char under the cursor).
#
# boba's input parser turns Ctrl+D into TUI_MSG_EOF — a semantic verdict, not
# a key press — and leaves the decision to the app. telnet_app_update() has to
# hand it back to the textinput as the ctrl+d key its delete-char path is
# written for, and must never quit the client on it.
#
# Exit code 77 = "skip" per autotools convention.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOP_SRCDIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
MUDLARK_BIN="${MUDLARK_BIN:-$TOP_SRCDIR/build/src/mudlark}"
TEST_SERVER="${TEST_SERVER:-$SCRIPT_DIR/test_server.py}"

if ! command -v tmux >/dev/null 2>&1; then
	echo "tmux not found; skipping" >&2
	exit 77
fi
if ! command -v python3 >/dev/null 2>&1; then
	echo "python3 not found; skipping" >&2
	exit 77
fi
if [ ! -x "$MUDLARK_BIN" ]; then
	echo "mudlark binary not found at $MUDLARK_BIN; skipping" >&2
	exit 77
fi

SESSION="mudlark-ctrl-d-$$"
SERVER_PID=

cleanup() {
	tmux kill-session -t "$SESSION" 2>/dev/null || true
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT

# Pick a free port so we don't collide with a running dev server on 4449.
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"

# Start the mock telnet server on PORT (test_server.py hardcodes 4449, so
# patch in memory before exec).
python3 -c "
src = open('$TEST_SERVER').read().replace('PORT = 4449', 'PORT = $PORT')
exec(compile(src, '$TEST_SERVER', 'exec'), {'__name__': '__main__'})
" &
SERVER_PID=$!

# Wait for the server to accept connections.
for _ in $(seq 1 50); do
	if python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.1).close()" 2>/dev/null; then
		break
	fi
	sleep 0.1
done

# Start mudlark inside tmux.
tmux new-session -d -s "$SESSION" -x 120 -y 40 \
	"$MUDLARK_BIN" 127.0.0.1 "$PORT"
sleep 0.5

pane() {
	tmux capture-pane -p -t "$SESSION"
}

dump() {
	echo "--- pane ---" >&2
	pane >&2
	echo "------------" >&2
}

assert_pane_contains() {
	if ! pane | grep -qF "$1"; then
		echo "FAIL: pane missing expected text: $1" >&2
		dump
		exit 1
	fi
}

assert_pane_missing() {
	if pane | grep -qF "$1"; then
		echo "FAIL: pane unexpectedly contains: $1" >&2
		dump
		exit 1
	fi
}

# 1. Plain typing reaches the textinput.
tmux send-keys -t "$SESSION" 'hello'
sleep 0.2
assert_pane_contains 'hello'

# 2. Ctrl+A to the start of the line, then Ctrl+D deletes the character
#    under the cursor (readline), not the line and not the session.
tmux send-keys -t "$SESSION" C-a
sleep 0.2
tmux send-keys -t "$SESSION" C-d
sleep 0.2
assert_pane_contains 'ello'
assert_pane_missing 'hello'

# 3. A second Ctrl+D deletes the next character: the key repeats.
tmux send-keys -t "$SESSION" C-d
sleep 0.2
assert_pane_contains 'llo'
assert_pane_missing 'ello'

# 4. Ctrl+D never quits: the session is still alive, still accepts input, and
#    the cursor stayed at the start of the line (delete-char does not move it).
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
	echo "FAIL: Ctrl+D quit the client" >&2
	exit 1
fi
tmux send-keys -t "$SESSION" '!'
sleep 0.2
assert_pane_contains '!llo'

echo PASS

#!/usr/bin/env bash
# tmux-driven test for Shift-Tab focus toggle between textinput and viewport.
#
# Drives mudlark inside a detached tmux session, sends keystrokes via
# `tmux send-keys`, and asserts on `tmux capture-pane` output.
#
# tmux key names: BTab = Shift-Tab, C-Space = Ctrl-Space, M-w = Alt-w.
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

SESSION="bloom-shift-tab-$$"
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

assert_pane_contains() {
	if ! tmux capture-pane -p -t "$SESSION" | grep -qF "$1"; then
		echo "FAIL: pane missing expected text: $1" >&2
		echo "--- pane ---" >&2
		tmux capture-pane -p -t "$SESSION" >&2
		echo "------------" >&2
		exit 1
	fi
}

assert_pane_missing() {
	if tmux capture-pane -p -t "$SESSION" | grep -qF "$1"; then
		echo "FAIL: pane unexpectedly contains: $1" >&2
		echo "--- pane ---" >&2
		tmux capture-pane -p -t "$SESSION" >&2
		echo "------------" >&2
		exit 1
	fi
}

# 1. Plain typing reaches textinput.
tmux send-keys -t "$SESSION" 'hello-textinput'
sleep 0.2
assert_pane_contains 'hello-textinput'

# 2. Shift-Tab moves focus to viewport; further typing must NOT reach textinput.
tmux send-keys -t "$SESSION" 'BTab'
sleep 0.2
tmux send-keys -t "$SESSION" 'SHOULD_NOT_APPEAR'
sleep 0.2
assert_pane_missing 'SHOULD_NOT_APPEAR'

# 3. Shift-Tab back returns focus to textinput; typing reaches it again.
tmux send-keys -t "$SESSION" 'BTab'
sleep 0.2
tmux send-keys -t "$SESSION" 'back-to-input'
sleep 0.2
assert_pane_contains 'back-to-input'

# 4. Plain Tab still routes to textinput (tab completion path is untouched).
#    Send Tab, then more text, and confirm typing still reaches textinput.
tmux send-keys -t "$SESSION" Tab
sleep 0.1
tmux send-keys -t "$SESSION" 'after-tab'
sleep 0.2
assert_pane_contains 'after-tab'

echo PASS

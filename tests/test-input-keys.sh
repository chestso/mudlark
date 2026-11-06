#!/usr/bin/env bash
# tmux-driven test for the input line's semantic keys: Ctrl+D, Ctrl+C and a
# bracketed paste.
#
# boba's input parser classifies these as TUI_MSG_EOF / TUI_MSG_INTERRUPT /
# TUI_MSG_PASTE — semantic messages, not key presses — and leaves the
# consequences to the app. telnet_app_update() has to:
#   Ctrl+D  delete the character under the cursor (readline), never quit
#   Ctrl+C  discard the line being typed (readline keyboard-quit)
#   paste   insert the payload as text, so a pasted newline is a newline and
#           does not submit the line
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

SESSION="mudlark-input-keys-$$"
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

# Start mudlark inside tmux. The pane stays alive after the client exits (the
# trailing sleep), so the last check can read the scrollback the client left
# behind.
tmux new-session -d -s "$SESSION" -x 120 -y 40 \
	sh -c "$MUDLARK_BIN 127.0.0.1 $PORT; sleep 60"
sleep 0.5

pane() {
	tmux capture-pane -p -t "$SESSION"
}

# The whole scrollback, not just the visible pane.
scrollback() {
	tmux capture-pane -p -S - -t "$SESSION"
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

assert_alive() {
	if ! tmux has-session -t "$SESSION" 2>/dev/null; then
		echo "FAIL: the client died: $1" >&2
		exit 1
	fi
}

# --- Ctrl+D: delete-char under the cursor -------------------------------

# Plain typing reaches the textinput.
tmux send-keys -t "$SESSION" 'hello'
sleep 0.2
assert_pane_contains 'hello'

# Ctrl+A to the start of the line, then Ctrl+D deletes the character under the
# cursor (readline), not the line and not the session.
tmux send-keys -t "$SESSION" C-a
sleep 0.2
tmux send-keys -t "$SESSION" C-d
sleep 0.2
assert_pane_contains 'ello'
assert_pane_missing 'hello'

# A second Ctrl+D deletes the next character: the key repeats.
tmux send-keys -t "$SESSION" C-d
sleep 0.2
assert_pane_contains 'llo'
assert_pane_missing 'ello'

assert_alive 'Ctrl+D'

# --- Ctrl+C: discard the line being typed -------------------------------

# The cursor is at the start of "llo"; Ctrl+C throws the line away.
tmux send-keys -t "$SESSION" C-c
sleep 0.2
assert_pane_missing 'llo'
assert_alive 'Ctrl+C'

# The input line still works afterwards.
tmux send-keys -t "$SESSION" 'fresh'
sleep 0.2
assert_pane_contains 'fresh'
tmux send-keys -t "$SESSION" C-c
sleep 0.2
assert_pane_missing 'fresh'
assert_alive 'Ctrl+C on a full line'

# --- Bracketed paste: text, not keystrokes ------------------------------

# The view declares bracketed paste, so tmux wraps a paste in the markers
# (tmux tracks the mode per pane). A line break in the payload must stay a
# line break: were it keystrokes, the first line would be submitted and the
# server would echo it back into the viewport.
printf 'alpha\nbeta' | tmux load-buffer -b mudlark-paste -
tmux paste-buffer -p -b mudlark-paste -t "$SESSION"
sleep 0.3
assert_pane_contains 'alpha'
assert_pane_contains 'beta'
PASTE_ECHOES="$(pane | grep -cF 'alpha' || true)"
if [ "$PASTE_ECHOES" != "1" ]; then
	echo "FAIL: pasted first line reached the server (submitted): saw 'alpha' $PASTE_ECHOES times" >&2
	dump
	exit 1
fi
assert_alive 'bracketed paste'

# --- Output survives :quit ----------------------------------------------

# Inline mode writes to the terminal's own scrollback, so what the session
# printed is still there after the client is gone.
tmux send-keys -t "$SESSION" 'scrollback-marker'
sleep 0.2
tmux send-keys -t "$SESSION" Enter
sleep 0.4
tmux send-keys -t "$SESSION" ':quit'
sleep 0.2
tmux send-keys -t "$SESSION" Enter
sleep 0.6

if ! scrollback | grep -qF 'scrollback-marker'; then
	echo "FAIL: the session's output did not survive :quit" >&2
	dump
	exit 1
fi
if ! scrollback | grep -qF 'Goodbye.'; then
	echo "FAIL: :quit left no goodbye line" >&2
	dump
	exit 1
fi

echo PASS

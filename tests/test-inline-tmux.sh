#!/usr/bin/env bash
# tmux-driven test for inline mode: the terminal's scrollback is the output
# history, the frame is only the live part.
#
# Asserts:
#   1. no alt screen: the client never leaves the primary buffer
#   2. server output lands in the terminal's scrollback (capture -S -)
#   3. a partial-line prompt (output with no trailing newline) stays open and
#      the next write continues it
#   4. a width change reflows the frame without stranding its old rows
#   5. a multi-line input grows the frame, and discarding it shrinks it back
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

# Two sessions: one against the mock server (output path) and one on its own
# (frame shape: resize and multi-line input need a quiet pane).
SESSION="mudlark-inline-$$"
BARE_SESSION="mudlark-inline-bare-$$"
SERVER_PID=

cleanup() {
	tmux kill-session -t "$SESSION" 2>/dev/null || true
	tmux kill-session -t "$BARE_SESSION" 2>/dev/null || true
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT

# Pick a free port so we don't collide with a running dev server on 4449.
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"

python3 -c "
src = open('$TEST_SERVER').read().replace('PORT = 4449', 'PORT = $PORT')
exec(compile(src, '$TEST_SERVER', 'exec'), {'__name__': '__main__'})
" &
SERVER_PID=$!

for _ in $(seq 1 50); do
	if python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.1).close()" 2>/dev/null; then
		break
	fi
	sleep 0.1
done

WIDTH=100
HEIGHT=30

# The pane stays alive after the client exits (the trailing sleep), so the
# scrollback is still there to be read.
#
# The sessions run in the source tree: the client finds its Lisp files
# (lisp/init.lisp and friends) relative to the working directory, and the
# hooks the test registers live there too.
tmux new-session -d -s "$SESSION" -x "$WIDTH" -y "$HEIGHT" -c "$TOP_SRCDIR" \
	sh -c "$MUDLARK_BIN 127.0.0.1 $PORT; sleep 60"
tmux new-session -d -s "$BARE_SESSION" -x "$WIDTH" -y "$HEIGHT" -c "$TOP_SRCDIR" \
	sh -c "$MUDLARK_BIN; sleep 60"
sleep 1.0

pane() { tmux capture-pane -p -t "$SESSION"; }
scrollback() { tmux capture-pane -p -S - -t "$SESSION"; }
bare_pane() { tmux capture-pane -p -t "$BARE_SESSION"; }

dump() {
	echo "--- pane ---" >&2
	pane >&2
	echo "------------" >&2
}

die() {
	echo "FAIL: $1" >&2
	dump
	exit 1
}

assert_scrollback_contains() {
	if ! scrollback | grep -qF "$1"; then
		die "scrollback missing expected text: $1"
	fi
}

# Lengths of the frame's divider rows: lines that are nothing but the
# horizontal rule. A quiet pane has exactly one of them.
divider_widths() {
	bare_pane | awk '/^─+$/ { print length($0) }'
}

# --- 1. No alt screen ---------------------------------------------------

ALTERNATE="$(tmux display -p -t "$SESSION" '#{alternate_on}')"
if [ "$ALTERNATE" != "0" ]; then
	die "the client is on the alternate screen (alternate_on=$ALTERNATE)"
fi

# --- 2. Server output lands in the scrollback ---------------------------

assert_scrollback_contains "Welcome to the Mudlark Test Server"

# --- 3. A partial-line prompt is continued by the next write ------------

# The server ends its turn with "> " and no newline: that prompt is an open
# row above the frame, and the echo of the next command continues it.
tmux send-keys -t "$SESSION" 'look'
sleep 0.2
tmux send-keys -t "$SESSION" Enter
sleep 0.5
if ! pane | grep -qE '^ *> *look *$'; then
	die "the server prompt was not continued by the echoed line"
fi

# --- 4. A width change reflows the frame without stranding rows ---------

BEFORE="$(divider_widths | tr '\n' ' ')"
if [ "$(echo "$BEFORE" | wc -w)" != "1" ]; then
	echo "FAIL: expected exactly one frame divider before resize, saw: $BEFORE" >&2
	echo "--- bare pane ---" >&2
	bare_pane >&2
	exit 1
fi

tmux resize-window -t "$BARE_SESSION" -x 60 -y 20
sleep 0.2
# A keystroke forces the next flush, which erases the reflowed old frame.
tmux send-keys -t "$BARE_SESSION" 'x'
sleep 0.4

AFTER="$(divider_widths | tr '\n' ' ')"
if [ "$(echo "$AFTER" | wc -w)" != "1" ]; then
	echo "FAIL: the resize stranded frame rows (dividers: $AFTER)" >&2
	echo "--- bare pane ---" >&2
	bare_pane >&2
	exit 1
fi
if [ "$(echo "$AFTER" | tr -d ' ')" != "60" ]; then
	echo "FAIL: the divider did not reflow to the new width (got $AFTER, want 60)" >&2
	echo "--- bare pane ---" >&2
	bare_pane >&2
	exit 1
fi

# --- 5. A multi-line input grows the frame and shrink brings it back ----

# A pasted line break is a second input row, not a submit.
printf 'alpha\nbeta' | tmux load-buffer -b mudlark-inline-paste -
tmux paste-buffer -p -b mudlark-inline-paste -t "$BARE_SESSION"
sleep 0.4
if ! bare_pane | grep -qF 'alpha' || ! bare_pane | grep -qF 'beta'; then
	echo "FAIL: the pasted multi-line input is not in the frame" >&2
	echo "--- bare pane ---" >&2
	bare_pane >&2
	exit 1
fi

# Ctrl+C discards the line: the frame shrinks back to the divider + one
# (empty) input row, and still exactly one divider is on screen.
tmux send-keys -t "$BARE_SESSION" C-c
sleep 0.4
if bare_pane | grep -qF 'alpha'; then
	echo "FAIL: Ctrl+C left the discarded line on screen" >&2
	echo "--- bare pane ---" >&2
	bare_pane >&2
	exit 1
fi
SHRUNK="$(divider_widths | tr '\n' ' ')"
if [ "$(echo "$SHRUNK" | wc -w)" != "1" ]; then
	echo "FAIL: the frame did not shrink cleanly (dividers: $SHRUNK)" >&2
	echo "--- bare pane ---" >&2
	bare_pane >&2
	exit 1
fi

echo PASS

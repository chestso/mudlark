#!/bin/sh
# Test wrapper script for mudlark tests
# Runs tests from the project root so (load "tests/...") and (load "lisp/...") work

# Get the directory containing this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Project root is one level up
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Find the ditty binary
if [ -n "$DITTY_BIN" ] && command -v "$DITTY_BIN" >/dev/null 2>&1; then
	REPL="$DITTY_BIN"
elif [ -x "$HOME/.local/bin/ditty" ]; then
	REPL="$HOME/.local/bin/ditty"
elif command -v ditty >/dev/null 2>&1; then
	REPL="ditty"
else
	echo "ERROR: ditty not found" >&2
	exit 1
fi

# Get the test file path
TEST_FILE="$1"
if [ -z "$TEST_FILE" ]; then
	echo "Usage: $0 <test-file.lisp>" >&2
	exit 1
fi

# Always normalize to tests/<basename> relative to project root
# This handles all cases: bare filename, relative path from build dir, absolute path
TEST_FILE="tests/$(basename "$TEST_FILE")"

# Run from project root
cd "$PROJECT_ROOT" || exit 1
exec "$REPL" "$TEST_FILE"

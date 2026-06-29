#!/bin/sh
# Test wrapper script for mudlark tests
# Runs tests from the project root so (load "tests/...") and (load "lisp/...") work

# Get the directory containing this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Project root is one level up
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Find the bloom-repl binary
if [ -n "$BLOOM_REPL" ] && command -v "$BLOOM_REPL" >/dev/null 2>&1; then
	REPL="$BLOOM_REPL"
elif [ -x "$HOME/.local/bin/bloom-repl" ]; then
	REPL="$HOME/.local/bin/bloom-repl"
elif command -v bloom-repl >/dev/null 2>&1; then
	REPL="bloom-repl"
else
	echo "ERROR: bloom-repl not found" >&2
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

#!/bin/sh
# Benchmark runner for mudlark
# Runs all bench-*.lisp files, or a specific one if given as argument

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

cd "$PROJECT_ROOT" || exit 1

if [ -n "$1" ]; then
	# Run a specific benchmark
	BENCH_FILE="tests/$(basename "$1")"
	echo "=== $BENCH_FILE ==="
	"$REPL" "$BENCH_FILE"
else
	# Run all benchmarks
	for f in tests/bench-*.lisp; do
		echo "=== $f ==="
		"$REPL" "$f"
		echo ""
	done
fi

#!/bin/sh
# Benchmark runner for mudlark
# Runs all bench-*.lisp files, or a specific one if given as argument

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

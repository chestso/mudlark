#!/bin/sh
# Build final spell-translator.lisp from template + dictionary + known-words
# This script assembles the complete spell-translator.lisp by combining:
# 1. spell-translator.lisp.template (base structure)
# 2. Auto-generated *spell-dictionary* entries
# 3. Auto-generated *known-spell-words* list
#
# Usage: build-aux/spell-translator/build-spell-translator.sh [log-dir]
# Default log-dir: ~/telnet-logs

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
LOGDIR="${1:-$HOME/telnet-logs}"

TEMPLATE="$PROJECT_ROOT/lisp/contrib/spell-translator.lisp.template"
OUTPUT="$PROJECT_ROOT/lisp/contrib/spell-translator.lisp"

# Check dependencies
if [ ! -f "$TEMPLATE" ]; then
	echo "ERROR: Template not found: $TEMPLATE" >&2
	echo "Run this script from the project root or ensure template exists" >&2
	exit 1
fi

if [ ! -d "$LOGDIR" ]; then
	echo "ERROR: Log directory not found: $LOGDIR" >&2
	echo "Usage: $0 [log-dir]" >&2
	exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DICT_ENTRIES="$TMP/dictionary_entries.txt"
KNOWN_WORDS="$TMP/known_words.txt"

echo "Building spell-translator.lisp from components..." >&2
echo "Template: $TEMPLATE" >&2
echo "Output: $OUTPUT" >&2
echo "Log directory: $LOGDIR" >&2

# ============================================================================
# Step 1: Generate dictionary entries using existing script
# ============================================================================
echo "Generating *spell-dictionary* entries..." >&2

if ! "$SCRIPT_DIR/spell-translator-suggest.sh" "$LOGDIR" >"$TMP/suggest_output.txt" 2>"$TMP/suggest_log.txt"; then
	echo "ERROR: Failed to generate dictionary entries" >&2
	cat "$TMP/suggest_log.txt" >&2
	exit 1
fi

# Extract dictionary entries from suggestion output
# Format the output as Lisp hash-set! calls with comments
{
	echo ""
	echo ";; Auto-generated dictionary overrides for cipher ambiguity corrections"
	echo ";; Based on analysis of telnet logs with Levenshtein-ranked hunspell suggestions"
	echo ";; Generated: $(date)"
	echo ""

	# Parse the suggestion output format: "garbled -> translation  hunspell: suggestions"
	awk '{
		garbled = $1
		translation = $3
		# Skip malformed lines
		if (length(garbled) > 0 && length(translation) > 0 && garbled != translation) {
			# Format as Lisp hash-set! call
			printf "(hash-set! *spell-dictionary* \"%s\" \"%s\")\n", garbled, translation
		}
	}' "$TMP/suggest_output.txt"

	echo ""
} >"$DICT_ENTRIES"

dict_count=$(grep -c "hash-set!" "$DICT_ENTRIES" || echo "0")
echo "Generated $dict_count dictionary entries" >&2

# ============================================================================
# Step 2: Generate known-spell-words using new script
# ============================================================================
echo "Generating *known-spell-words* list..." >&2

# Use reasonable defaults for minimality (can be overridden with environment variables)
MIN_FREQUENCY="${MIN_FREQUENCY:-2}"
MIN_SPELL_SCORE="${MIN_SPELL_SCORE:-30}"
MAX_KNOWN_WORDS="${MAX_KNOWN_WORDS:-8}"

if ! MIN_FREQUENCY="$MIN_FREQUENCY" MIN_SPELL_SCORE="$MIN_SPELL_SCORE" \
	"$SCRIPT_DIR/generate-known-spell-words.sh" "$LOGDIR" "$MAX_KNOWN_WORDS" \
	>"$TMP/known_words_output.txt" 2>"$TMP/known_words_log.txt"; then
	echo "ERROR: Failed to generate known-spell-words" >&2
	cat "$TMP/known_words_log.txt" >&2
	exit 1
fi

# Extract the known-words definition and inject spells the miner cannot
# recover from current logs:
#   invis  - hunspell rejects it, so the readable-utterance gate drops every
#            utterance containing it
#   cure   - not present in current logs; injected preemptively so cleric
#            same-class utterances are recognized once they appear
{
	echo ""
	echo ";; Auto-generated known-spell-words from readable utterance analysis"
	echo ";; Generated: $(date)"

	# Spells the miner cannot recover from logs (see comment above)
	mud_words='"cure" "invis"'

	sed -n '/^(defvar \*known-spell-words\*/,/))$/p' "$TMP/known_words_output.txt" |
		sed "s|))$|  $mud_words)) ; injected: invis (hunspell-rejected), cure (not yet in logs)|"

	echo ""
} >"$KNOWN_WORDS"

known_count=$(grep -o '"[^"]*"' "$KNOWN_WORDS" | wc -l)
echo "Generated known-spell-words with $known_count entries" >&2

# ============================================================================
# Step 3: Assemble final file from template
# ============================================================================
echo "Assembling final spell-translator.lisp..." >&2

# Use sed to replace placeholders in template
sed \
	-e '/{{KNOWN_SPELL_WORDS}}/{
		r '"$KNOWN_WORDS"'
		d
	}' \
	-e '/{{SPELL_DICTIONARY_ENTRIES}}/{
		r '"$DICT_ENTRIES"'
		d
	}' \
	"$TEMPLATE" >"$OUTPUT"

echo "Build complete: $OUTPUT" >&2
echo "Dictionary entries: $dict_count" >&2
echo "Known spell words: $known_count" >&2

# ============================================================================
# Step 4: Validation
# ============================================================================
echo "Validating generated file..." >&2

# Basic syntax check - count parentheses
open_parens=$(grep -o '(' "$OUTPUT" | wc -l)
close_parens=$(grep -o ')' "$OUTPUT" | wc -l)

if [ "$open_parens" -ne "$close_parens" ]; then
	echo "WARNING: Unbalanced parentheses in output ($open_parens open, $close_parens close)" >&2
fi

# Check for placeholder leakage
if grep -q '{{.*}}' "$OUTPUT"; then
	echo "ERROR: Template placeholders not replaced:" >&2
	grep '{{.*}}' "$OUTPUT" >&2
	exit 1
fi

# Check for required sections
required_sections="defvar.*known-spell-words defvar.*spell-dictionary hash-set!.*spell-dictionary"
for section in $required_sections; do
	if ! grep -q "$section" "$OUTPUT"; then
		echo "WARNING: Missing required section: $section" >&2
	fi
done

echo "Validation complete" >&2

# ============================================================================
# Optional: Show build summary with analysis
# ============================================================================
if [ "${VERBOSE:-}" = "1" ]; then
	echo "" >&2
	echo "=== BUILD SUMMARY ===" >&2
	echo "Template: $(wc -l <"$TEMPLATE") lines" >&2
	echo "Dictionary: $dict_count entries" >&2
	echo "Known words: $known_count words" >&2
	echo "Output: $(wc -l <"$OUTPUT") lines" >&2
	echo "" >&2

	echo "Known spell words generated:" >&2
	grep -o '"[^"]*"' "$KNOWN_WORDS" | sed 's/"//g' | while read word; do
		echo "  $word" >&2
	done

	echo "" >&2
	cat "$TMP/suggest_log.txt" >&2
	cat "$TMP/known_words_log.txt" >&2
fi

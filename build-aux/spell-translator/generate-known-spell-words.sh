#!/bin/sh
# Generate optimal *known-spell-words* list from telnet log analysis
# Analyzes readable (non-garbled) utterances to find words that need
# *known-spell-words* coverage to prevent translation.
#
# Usage: build-aux/spell-translator/generate-known-spell-words.sh [log-dir] [max-words]
# Default log-dir: ~/telnet-logs
# Default max-words: 10

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
LOGDIR="${1:-$HOME/telnet-logs}"
MAX_WORDS="${2:-10}"

# Minimality constraints
MIN_FREQUENCY="${MIN_FREQUENCY:-5}"  # High frequency threshold for minimality
MIN_SPELL_SCORE="${MIN_SPELL_SCORE:-50}"  # Minimum spell-domain relevance score

if [ ! -d "$LOGDIR" ]; then
	echo "ERROR: log directory not found: $LOGDIR" >&2
	echo "Usage: $0 [log-dir] [max-words]" >&2
	echo "Environment: MIN_FREQUENCY=$MIN_FREQUENCY MIN_SPELL_SCORE=$MIN_SPELL_SCORE" >&2
	exit 1
fi

# Find bloom-repl (same logic as spell-translator-suggest.sh)
if [ -n "${BLOOM_REPL:-}" ] && command -v "$BLOOM_REPL" >/dev/null 2>&1; then
	REPL="$BLOOM_REPL"
elif [ -x "$HOME/.local/bin/bloom-repl" ]; then
	REPL="$HOME/.local/bin/bloom-repl"
elif command -v bloom-repl >/dev/null 2>&1; then
	REPL="bloom-repl"
else
	echo "ERROR: bloom-repl not found" >&2
	exit 1
fi

if ! command -v hunspell >/dev/null 2>&1; then
	echo "ERROR: hunspell not found (dnf install hunspell)" >&2
	exit 1
fi

# Check for log files
if ! ls "$LOGDIR"/*.log >/dev/null 2>&1; then
	echo "ERROR: No .log files found in $LOGDIR" >&2
	exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

UTT_ALL="$TMP/utterances_all.txt"
READABLE_UTT="$TMP/readable_utterances.txt"
ALL_WORDS="$TMP/all_words.txt"
DICT_VALUES="$TMP/dict_values.txt"
CANDIDATES="$TMP/candidates.txt"
SCORED="$TMP/scored.txt"

echo "Generating minimal known-spell-words from $LOGDIR..." >&2
echo "Constraints: max_words=$MAX_WORDS, min_frequency=$MIN_FREQUENCY, min_spell_score=$MIN_SPELL_SCORE" >&2

# ============================================================================
# Reuse hunspell compound recovery from spell-translator-suggest.sh
# ============================================================================
spellcheck_misspelled() {
	hunspell -a 2>/dev/null | awk -F'	' '
	function compound_match(word, sugs,    n, parts, i, joined) {
		n = split(sugs, parts, ", ")
		for (i = 1; i <= n; i++) {
			joined = parts[i]
			gsub(/[ \-]/, "", joined)
			if (tolower(joined) == tolower(word)) return 1
		}
		return 0
	}
	/^& / {
		rest = substr($0, 3)
		colon = index(rest, ":")
		split(substr(rest, 1, colon - 1), h, " ")
		sugs = substr(rest, colon + 2)
		if (!compound_match(h[1], sugs)) print h[1]
		next
	}
	/^# / {
		split(substr($0, 3), h, " ")
		print h[1]
	}'
}

# ============================================================================
# Step 1: Extract all utterances and dedup with occurrence counts.
# Each line is "<count><TAB><utterance>"; preserving the count is critical
# because frequency is what ranks candidates downstream — collapsing with
# `sort -u` would map 138 same-class 'armor' utterances to a single line.
# ============================================================================
grep -hoE "utters the words, '[^']+'" "$LOGDIR"/*.log 2>/dev/null \
	| sed -E "s/^utters the words, '(.+)'$/\1/" \
	| sort | uniq -c | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+/\1\t/' >"$UTT_ALL"
echo "Extracted $(wc -l <"$UTT_ALL") unique utterances" >&2

# ============================================================================
# Step 2: Identify readable utterances (all words pass hunspell). Each line
# preserves the upstream count column so step 4 can weight word frequency.
# ============================================================================
{
	while IFS=$'\t' read -r count utterance; do
		all_readable=true
		# Check each word in utterance
		for word in $utterance; do
			# Convert to lowercase for consistency
			word_lower=$(echo "$word" | tr '[:upper:]' '[:lower:]')
			# Check if word is misspelled (not in hunspell dictionary)
			if echo "$word_lower" | spellcheck_misspelled | grep -q "^$word_lower$"; then
				all_readable=false
				break
			fi
		done
		# If all words are readable, keep this utterance with its count
		[ "$all_readable" = true ] && printf '%s\t%s\n' "$count" "$utterance"
	done <"$UTT_ALL"
} >"$READABLE_UTT"
echo "Readable utterances: $(wc -l <"$READABLE_UTT")" >&2

# Check minimum data requirement
MIN_READABLE=5
if [ "$(wc -l <"$READABLE_UTT")" -lt "$MIN_READABLE" ]; then
	echo "WARNING: Only $(wc -l <"$READABLE_UTT") readable utterances found (minimum: $MIN_READABLE)" >&2
	echo "Results may not be representative" >&2
fi

# ============================================================================
# Step 3: Extract current *spell-dictionary* values to avoid duplicates
# ============================================================================
cd "$PROJECT_ROOT"
"$REPL" build-aux/spell-translator/extract-spell-dict-values.lisp >"$DICT_VALUES" 2>/dev/null || {
	echo "ERROR: Failed to extract spell-dictionary values" >&2
	exit 1
}
echo "Current spell-dictionary values: $(wc -l <"$DICT_VALUES")" >&2

# ============================================================================
# Step 4: Extract candidate words from readable utterances, weighted by the
# count column so frequency reflects how often the word was actually said.
# ============================================================================
awk -F'\t' '
{
	count = $1
	n = split(tolower($2), words, " ")
	for (i = 1; i <= n; i++) {
		if (words[i] != "") word_freq[words[i]] += count
	}
}
END {
	for (w in word_freq) printf "%d %s\n", word_freq[w], w
}' "$READABLE_UTT" | sort -nr >"$ALL_WORDS"

# Filter out words covered by spell-dictionary values and common English
awk -v min_freq="$MIN_FREQUENCY" '
function is_common_english(word) {
	return match(word, /^(the|and|for|are|but|not|you|all|can|had|her|was|one|our|out|day|get|has|him|his|how|its|may|new|now|old|see|two|way|who|boy|did|man|men|put|say|she|too|use|with|have|from|they|know|want|been|good|much|some|time|very|when|come|here|just|like|long|make|many|over|such|take|than|them|well|were|will|your|said|each|which|their|would|there|could|other|after|first|never|these|think|where|being|every|great|might|shall|still|those|while|again|place|right|years|young|should|little)$/)
}

function is_covered_by_dict(word,    i) {
	# Coverage means the dictionary already produces this exact word as a
	# translation. Substring overlap does not — short translation values
	# like "ar"/"mor" are real 2-3 letter words, not coverage proxies.
	for (i = 1; i <= dict_count; i++) {
		if (tolower(word) == tolower(dict_values[i])) return 1
	}
	return 0
}

BEGIN {
	dict_count = 0
	while ((getline dict_value < "'"$DICT_VALUES"'") > 0) {
		dict_values[++dict_count] = dict_value
	}
	close("'"$DICT_VALUES"'")
}

$1 >= min_freq && !is_common_english($2) && !is_covered_by_dict($2) {
	print $1, $2
}
' "$ALL_WORDS" >"$CANDIDATES"

echo "Candidate words (after filtering): $(wc -l <"$CANDIDATES")" >&2

# ============================================================================
# Step 5: Apply spell-domain scoring and rank
# ============================================================================
awk -v min_score="$MIN_SPELL_SCORE" '
function spell_domain_score(word) {
	score = 0

	# High-value spell actions
	if (match(word, /(cure|heal|bless|protect|ward|shield|armor|resist|dispel|banish)/))
		score += 100
	# Elements and magic types
	else if (match(word, /(fire|ice|frost|lightning|acid|poison|holy|unholy|shadow|divine|arcane)/))
		score += 80
	# Magic terms
	else if (match(word, /(magic|mana|spell|enchant|charm|illusion|summon|invoke|conjure)/))
		score += 90
	# Body parts (common in spells)
	else if (match(word, /(mind|body|spirit|soul|heart|bone|flesh|blood)/))
		score += 70
	# Descriptors
	else if (match(word, /(greater|lesser|major|minor|mass|area|group|self)/))
		score += 60
	# Spell-like actions
	else if (match(word, /(create|destroy|detect|identify|locate|transport|teleport)/))
		score += 50

	# Length bonus for longer words (spell terms tend to be longer)
	if (length(word) >= 8) score += 20
	else if (length(word) >= 6) score += 10

	return score
}

{
	freq = $1
	word = $2

	spell_score = spell_domain_score(word)

	# Only consider words with sufficient spell relevance
	if (spell_score >= min_score) {
		# Total score: spell relevance + frequency boost + length
		total_score = spell_score + (freq * 10) + length(word)
		print total_score, freq, spell_score, word
	}
}
' "$CANDIDATES" | sort -nr >"$SCORED"

echo "Spell-domain candidates (score >=$MIN_SPELL_SCORE): $(wc -l <"$SCORED")" >&2

# ============================================================================
# Step 6: Generate output with minimality analysis
# ============================================================================
generate_output() {
	local max_words="$1"

	echo ";; Auto-generated known-spell-words list from telnet log analysis"
	echo ";; Generated: $(date)"
	echo ";; Log directory: $LOGDIR"
	echo ";; Analysis: $(wc -l <"$UTT_ALL") total utterances, $(wc -l <"$READABLE_UTT") readable"
	echo ";; Constraints: min_frequency=$MIN_FREQUENCY, min_spell_score=$MIN_SPELL_SCORE"
	echo ";; Current spell-dictionary coverage: $(wc -l <"$DICT_VALUES") values"
	echo ""

	if [ "$(wc -l <"$SCORED")" -eq 0 ]; then
		echo "(defvar *known-spell-words* '()) ; No candidates met minimality criteria"
		echo ""
		echo ";; All readable utterances appear to be covered by existing spell-dictionary"
		echo ";; or contain only common English words. Consider lowering MIN_SPELL_SCORE"
		echo ";; if more coverage is needed."
		return
	fi

	echo "(defvar *known-spell-words* '("
	head -n "$max_words" "$SCORED" | \
		awk '{ printf "  \"%s\"\n", $4 }' | \
		sed '$ s/$/))/'

	echo ""
	echo ";; Minimality analysis - top candidates ranked by relevance + frequency:"
	head -n 20 "$SCORED" | \
		awk '{
			marker = (NR <= '"$max_words"') ? "*" : " "
			printf ";;%s %2d. %-15s (total: %3d, spell: %2d, freq: %2d)\\n",
				marker, NR, $4, $1, $3, $2
		}'

	if [ "$(wc -l <"$SCORED")" -gt 20 ]; then
		echo ";; ... $(expr $(wc -l <"$SCORED") - 20) additional candidates available"
	fi

	# Coverage analysis: weighted by occurrence count from the count column
	# so the percentage reflects spoken frequency, not distinct phrasings.
	covered_utterances=$(awk -F'\t' '
		BEGIN {
			word_count = 0
			while ((getline < "'"$TMP"'/top_words.tmp") > 0) {
				top_words[++word_count] = $0
			}
			close("'"$TMP"'/top_words.tmp")

			coverage = 0
			total = 0
		}
		{
			count = $1
			total += count
			utterance = tolower($2)
			covered = 0
			for (i = 1; i <= word_count; i++) {
				if (index(utterance, top_words[i]) > 0) {
					covered = 1
					break
				}
			}
			if (covered) coverage += count
		}
		END {
			printf "%.1f", (total > 0) ? (coverage * 100.0 / total) : 0.0
		}
	' "$READABLE_UTT" < <(head -n "$max_words" "$SCORED" | awk '{print $4}' | tee "$TMP/top_words.tmp"))

	echo ""
	echo ";; Coverage: Top $max_words words would prevent translation of $covered_utterances% of readable utterances"
}

# Generate main output
generate_output "$MAX_WORDS"

# Statistics for stderr
echo "" >&2
echo "=== Generation Complete ===" >&2
echo "Final known-spell-words candidates: $([ "$(wc -l <"$SCORED")" -lt "$MAX_WORDS" ] && wc -l <"$SCORED" || echo "$MAX_WORDS")" >&2
echo "Total spell-domain words available: $(wc -l <"$SCORED")" >&2
if [ "$(wc -l <"$SCORED")" -gt "$MAX_WORDS" ]; then
	echo "Truncated to $MAX_WORDS for minimality (override with larger max-words parameter)" >&2
fi
#!/bin/sh
# Translate every unique garbled word that appears in telnet log utterances
# with *spell-dictionary* cleared, then run the algorithmic translations
# through hunspell and print every misspelled translation alongside its
# garbled source and hunspell's suggestions. Output is the working list of
# candidates to add to lisp/contrib/spell-translator.lisp's *spell-dictionary*.
#
# Usage: tests/spell-translator-suggest.sh [log-dir]
# Default log-dir: ~/telnet-logs

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LOGDIR="${1:-$HOME/telnet-logs}"

if [ ! -d "$LOGDIR" ]; then
	echo "ERROR: log directory not found: $LOGDIR" >&2
	exit 1
fi

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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
UTT_ALL="$TMP/utterances.all"
UTT="$TMP/utterances.garbled"
ALL_WORDS="$TMP/words.all"
BAD_WORDS="$TMP/words.bad"
PAIRS="$TMP/pairs.tsv"
WORDS="$TMP/words"
MISS="$TMP/miss.tsv"

# Run hunspell on stdin and emit "<word>\t<suggestions>" only for words that
# are *truly* misspelled. Two transforms applied to hunspell's raw output:
#
#  1. Compound recovery — drop the word entirely if any suggestion, with
#     internal spaces and hyphens removed, equals the original word
#     case-insensitively. Catches compound spell names like `nightgaunt`
#     (suggestion "night gaunt") and `wraithform` ("wraith form") that the
#     English dict doesn't contain but are real words.
#
#  2. Suggestion reranking — hunspell's ranking is mediocre for spelling
#     drift produced by the cipher (e.g. `concellotion` should map to
#     `cancellation` but hunspell puts `conceptional` first). Sort the
#     suggestions by Levenshtein distance to the misspelled word, ascending,
#     so the closest candidate is first.
spellcheck_misspelled() {
	hunspell -a 2>/dev/null | awk -F'	' '
	function lev(a, b,    la, lb, i, j, cost, mn, dp) {
		la = length(a); lb = length(b)
		if (la == 0) return lb
		if (lb == 0) return la
		for (i = 0; i <= la; i++) dp[i, 0] = i
		for (j = 0; j <= lb; j++) dp[0, j] = j
		for (i = 1; i <= la; i++) {
			for (j = 1; j <= lb; j++) {
				cost = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
				mn = dp[i-1, j-1] + cost
				if (dp[i-1, j] + 1 < mn) mn = dp[i-1, j] + 1
				if (dp[i, j-1] + 1 < mn) mn = dp[i, j-1] + 1
				dp[i, j] = mn
			}
		}
		return dp[la, lb]
	}
	function compound_match(word, sugs,    n, parts, i, joined, m, frags, j, ok) {
		# Only accept a compound suggestion as recovery when every part is
		# at least 3 letters. Hunspell loves to split unknown words into
		# fragments like "brag h" or "lo cote" that rejoin to the input
		# but are not real compound words.
		n = split(sugs, parts, ", ")
		for (i = 1; i <= n; i++) {
			joined = parts[i]
			gsub(/[ \-]/, "", joined)
			if (tolower(joined) != tolower(word)) continue
			ok = 1
			m = split(parts[i], frags, /[ \-]/)
			for (j = 1; j <= m; j++) {
				if (length(frags[j]) < 3) { ok = 0; break }
			}
			if (ok) return 1
		}
		return 0
	}
	function rerank(word, sugs,    n, parts, i, j, t, dist, idx, out) {
		n = split(sugs, parts, ", ")
		if (n <= 1) return sugs
		for (i = 1; i <= n; i++) {
			idx[i] = i
			dist[i] = lev(tolower(word), tolower(parts[i]))
		}
		for (i = 1; i < n; i++) {
			for (j = i + 1; j <= n; j++) {
				if (dist[idx[j]] < dist[idx[i]]) {
					t = idx[i]; idx[i] = idx[j]; idx[j] = t
				}
			}
		}
		out = parts[idx[1]]
		for (i = 2; i <= n; i++) out = out ", " parts[idx[i]]
		return out
	}
	/^& / {
		rest = substr($0, 3)
		colon = index(rest, ":")
		split(substr(rest, 1, colon - 1), h, " ")
		sugs = substr(rest, colon + 2)
		if (!compound_match(h[1], sugs)) print h[1] "\t" rerank(h[1], sugs)
		next
	}
	/^# / {
		split(substr($0, 3), h, " ")
		print h[1] "\t"
	}'
}

# Step 1: extract every "utters the words, '...'" payload, uniq them.
# Logs use literal "\n\r" between RECV chunks — utterances aren't always on
# their own line, so use grep -o.
grep -hoE "utters the words, '[^']+'" "$LOGDIR"/*.log 2>/dev/null |
	sed -E "s/^utters the words, '(.+)'$/\1/" |
	sort -u >"$UTT_ALL"
echo "Extracted $(wc -l <"$UTT_ALL") unique utterances from $LOGDIR" >&2

# Step 1b: a "garbled" utterance is one with any word not in the English
# dictionary (after compound recovery). Spell-check every distinct token once.
tr ' ' '\n' <"$UTT_ALL" | sort -u >"$ALL_WORDS"
spellcheck_misspelled <"$ALL_WORDS" | awk -F'	' '{print $1}' | sort -u >"$BAD_WORDS"
echo "Non-dictionary words (after compound recovery): $(wc -l <"$BAD_WORDS")" >&2

# An utterance is "garbled" only when *every* word is non-English. A single
# real English word (or MUD-shorthand like "invis") means the utterance is
# already readable to the player and should not be cipher-translated.
awk 'NR==FNR { bad[$1] = 1; next }
     { all_bad = 1
       for (i = 1; i <= NF; i++) if (!($i in bad)) { all_bad = 0; break }
       if (all_bad && NF > 0) print
     }
' "$BAD_WORDS" "$UTT_ALL" >"$UTT"
echo "Garbled utterances: $(wc -l <"$UTT")" >&2

# Step 2: Lisp emits "garbled<TAB>algorithmic-translation" per unique garbled
# word, *spell-dictionary* cleared.
cd "$PROJECT_ROOT"
"$REPL" tests/spell-translator-suggest.lisp -- "$UTT" | sort -u >"$PAIRS"
echo "Translated $(wc -l <"$PAIRS") unique garbled words" >&2

# Step 3: spell-check the translation column with the same compound-aware
# pass, then join surviving misspellings back to their garbled source.
awk -F'	' '{print $2}' "$PAIRS" | sort -u >"$WORDS"
spellcheck_misspelled <"$WORDS" >"$MISS"

awk -F'	' '
function lev(a, b,    la, lb, i, j, cost, mn, dp) {
    la = length(a); lb = length(b)
    if (la == 0) return lb
    if (lb == 0) return la
    for (i = 0; i <= la; i++) dp[i, 0] = i
    for (j = 0; j <= lb; j++) dp[0, j] = j
    for (i = 1; i <= la; i++) {
        for (j = 1; j <= lb; j++) {
            cost = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
            mn = dp[i-1, j-1] + cost
            if (dp[i-1, j] + 1 < mn) mn = dp[i-1, j] + 1
            if (dp[i, j-1] + 1 < mn) mn = dp[i, j-1] + 1
            dp[i, j] = mn
        }
    }
    return dp[la, lb]
}
BEGIN {
    # Hardcoded overrides: garbled -> correct mappings the algorithm
    # cannot infer because either:
    #   (a) the correct word is game-specific and not in hunspell
    #       (e.g. archon, kaubris)
    #   (b) hunspell ranks a wrong suggestion first and Levenshtein
    #       cannot disambiguate between equidistant candidates
    #       (e.g. confute vs confuse vs conjure for "confure")
    overrides["abraq"]          = "arc"           # cipher: olc; from "zzggag abraq" -> "vessas arc"
    overrides["abraqpai"]       = "archon"        # hunspell suggests "arson"
    overrides["aecandusiar"]    = "adrenal"       # cipher: odrenol; hunspell suggests "retinol"
    overrides["aepzguzz"]       = "adhesive"      # cipher: odhesiee; hunspell suggests "adhesion"
    overrides["bcandusahp"]     = "breath"        # "frost breath"; hunspell ties broth/breath at Lev 1
    overrides["bragh"]          = "blast"         # "psionic blast"; hunspell ranks "bloat" first
    overrides["gpaszgpuyh"]     = "shapeshift"    # hunspell suggests "shoplift"
    overrides["gqarzg"]         = "scales"        # "scales of the dragon"; hunspell ranks "soles" first
    overrides["hpkadawahjfouq"] = "thaumaturgic"  # hunspell suggests "liturgical"
    overrides["iaza"]           = "nova"          # cipher: noeo
    overrides["oculoqarquyl"]   = "decalcify"     # cipher: decolcify; hunspell suggests "decollete"
    overrides["paghz"]          = "haste"         # cipher: hoste; hunspell ranks "host" first
    overrides["pzah"]           = "heat"          # "channel heat"; hunspell ranks "hot" first
    overrides["qaiyjcandus"]    = "conjure"       # "conjure elemental"; hunspell ties at confute/confuse/conjure
    overrides["qpaui"]          = "chain"         # "chain lightning"; hunspell ties chin/coin/chain at Lev 1
    overrides["ruzuio"]         = "living"        # "armor of living bone"; hunspell ties lining/living at Lev 1
    overrides["tkadabfug"]      = "kaubris"       # hunspell suggests "hubris"
    overrides["uiygruzuguai"]   = "infravision"   # hunspell suggests "infrasonic"
    overrides["uizug"]          = "invis"         # cipher: ineis; MUD spell shorthand
    overrides["waraugz"]        = "malaise"       # cipher: moloise; hunspell suggests "seismology"
    overrides["wugrzae"]        = "mislead"       # hunspell ties at misled/mislead
    overrides["wunsohar"]       = "mental"        # "mental knife"; hunspell ties at menthol/mental
    overrides["xzatunso"]       = "weaken"        # cipher: weoken; hunspell ranks "woken" first
    overrides["yarh"]           = "jolt"          # "mental jolt"; cipher: folt (y is the j-form, not f)
    overrides["yrawzg"]         = "flames"        # cipher: flomes
    overrides["zawsufuq"]       = "vampiric"      # hunspell suggests "empiric"
    overrides["zzggag"]         = "vessas"        # cipher: eessos; from "zzggag abraq" -> "vessas arc"
}
NR==FNR {
    sugs = $2
    if (sugs == "") sugs = "(no suggestions)"
    miss[$1] = sugs
    next
}
$2 in miss {
    # Decide whether to emit a dictionary entry, and what to map to.
    # Only emit entries we are confident about — the runtime cipher
    # already runs on every word, so a missing dict entry just falls
    # through to cipher. Bad dict entries actively poison the output.
    #
    # Priority:
    #   1. Hardcoded override for this garbled word -> use it
    #   2. Top hunspell suggestion at Levenshtein <= 1 -> high confidence
    #   3. Multi-suggestion consensus with top at Levenshtein <= 2 ->
    #      rules out cipher-correct words being clobbered
    #   4. Otherwise -> skip (the cipher output is either correct already
    #      or unrecoverable; either way no good dict entry to add)
    sugs = miss[$2]
    emit = 0
    if ($1 in overrides) {
        corrected = overrides[$1]
        emit = 1
    } else if (sugs != "(no suggestions)") {
        n = split(sugs, parts, ", ")
        d = lev(tolower($2), tolower(parts[1]))
        if (d <= 1) {
            corrected = parts[1]
            emit = 1
        } else if (n > 1 && d <= 2) {
            corrected = parts[1]
            emit = 1
        }
    }
    if (emit) printf "%-22s -> %-22s  hunspell: %s\n", $1, corrected, sugs
}
' "$MISS" "$PAIRS" | sort

echo "" >&2
echo "Truly misspelled translations: $(wc -l <"$MISS")" >&2

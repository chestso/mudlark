;;; spell-translator.lisp --- Translate garbled spell utterances (ROM 2.4 cipher)
;;;
;;; This script was created for Carrion Fields MUD (https://carrionfields.net/)
;;;
;;; Usage:
;;;   (load "contrib/spell-translator.lisp")
;;;
;;; When someone casts a spell, you see:
;;;   Det utters the words, 'qaiyjcandus zrzwunsohar'.
;;;
;;; This script weaves in a translation right after the spell:
;;;   Det utters the words, 'qaiyjcandus zrzwunsohar' (conjure elemental).
;;;
;;; The ROM 2.4 MUD garble algorithm uses syllable substitution followed by
;;; single-character substitution. This script reverses that process.
;;;
;;; Commands:
;;;   (spell-add "garbled" "correct")    Add a dictionary override
;;;   (spell-remove "garbled")           Remove a dictionary override
;;;   (spell-add-known "word")           Add a known spell word (skips translation)
;;;   (spell-remove-known "word")        Remove a known spell word
;;;
;;; Data:
;;;   *spell-dictionary*   — garbled word overrides
;;;   *known-spell-words*  — words that skip translation
;;; ============================================================================
;;; Reverse Cipher Tables (ROM 2.4 magic.c)
;;; ============================================================================
;; Reverse syllable table - sorted by length (longest first for greedy matching)
;; Original ROM: ar→abra, au→kada, etc. This is the reverse.
(define *spell-reverse-syllables*
  '(("candus" . "re") ("oculo" . "de") ("sabru" . "son") ("infra" . "tect")
    ("lacri" . "ness") ("abra" . "ar") ("kada" . "au") ("fido" . "bless")
    ("nose" . "blind") ("mosa" . "bur") ("judi" . "cu") ("unso" . "en")
    ("dies" . "light") ("sido" . "move") ("illa" . "ning") ("duda" . "per")
    ("cula" . "tri") ("nofo" . "ven") ("gru" . "ra") ("ima" . "fresh")
    ("zak" . "mor") ("hi" . "lo")))

;; Reverse single-character table
;; Ambiguous mappings (a→a/o, z→e/v, y→f/j) default to most common letter
(define *spell-reverse-chars*
  '((#\a . #\o) ; ambiguous: seems to be way more `o`s than `a`s
    (#\b . #\b) (#\q . #\c) (#\e . #\d) (#\z . #\e) ; ambiguous: could be 'v', defaulting to 'e'
    (#\y . #\f) ; ambiguous: could be 'j', defaulting to 'f'
    (#\o . #\g) (#\p . #\h) (#\u . #\i) (#\t . #\k) (#\r . #\l) (#\w . #\m)
    (#\i . #\n) (#\s . #\p) (#\d . #\q) (#\f . #\r) (#\g . #\s) (#\h . #\t)
    (#\j . #\u) (#\n . #\x) (#\l . #\y) (#\k . #\z) (#\x . #\w) (#\c . #\c) ; fallback - not in original cipher
    (#\m . #\m) ; fallback - not in original cipher
    (#\v . #\v))) ; fallback - not in original cipher

;;; ============================================================================
;;; Known Spell Words (skip translation for same-class visibility)
;;; ============================================================================
;; When you're the same class as the caster, you see the real spell name.
;; If any word in the utterance matches a known spell word, skip translation.

;; Auto-generated known-spell-words from readable utterance analysis
;; Generated: Wed May  6 11:30:50 AM +07 2026
(defvar *known-spell-words* '(
  "resist"
  "lightning"
  "detect"  "cure" "invis")) ; injected: MUD shorthand (cure, invis) hunspell does not know


;; Check if utterance contains any known spell word
(defun known-spell? (phrase)
  "Return true if phrase contains any known spell word (no translation needed)"
  (let ((lower-phrase (string-downcase phrase)))
    (or (known-spell-check-list lower-phrase *known-spell-words*)
        (dictionary-spell? lower-phrase))))

;; Recursively check if phrase contains any word from the list
(defun known-spell-check-list (phrase words)
  "Check if phrase contains any word from the list"
  (if (null? words)
    nil
    (if (string-contains? phrase (car words))
      #t
      (known-spell-check-list phrase (cdr words)))))

;; Check if phrase contains any dictionary correction word
(defun dictionary-spell? (phrase)
  "Return true if phrase contains any dictionary correction word"
  (dictionary-spell-check-keys phrase (hash-keys *spell-dictionary*)))

(defun dictionary-spell-check-keys (phrase keys)
  "Recursively check if phrase contains any dictionary value"
  (if (null? keys)
    nil
    (if (string-contains? phrase (hash-ref *spell-dictionary* (car keys)))
      #t
      (dictionary-spell-check-keys phrase (cdr keys)))))

;;; ============================================================================
;;; Dictionary Overrides
;;; ============================================================================
;; Hash table for word overrides (garbled → correct)
;; Users can add entries with (spell-add "garbled" "correct")
(defvar *spell-dictionary* (make-hash-table))


;; Auto-generated dictionary overrides for cipher ambiguity corrections
;; Based on analysis of telnet logs with Levenshtein-ranked hunspell suggestions
;; Generated: Wed May  6 11:30:47 AM +07 2026

(hash-set! *spell-dictionary* "abrahuyaqh" "artifact")
(hash-set! *spell-dictionary* "abraqpai" "archon")
(hash-set! *spell-dictionary* "abyzqh" "object")
(hash-set! *spell-dictionary* "aecandusiar" "adrenal")
(hash-set! *spell-dictionary* "aepzguzz" "adhesive")
(hash-set! *spell-dictionary* "afoai" "gorgon")
(hash-set! *spell-dictionary* "aiozr" "angel")
(hash-set! *spell-dictionary* "aiqpaf" "anchor")
(hash-set! *spell-dictionary* "aqqzrzgruhz" "accelerate")
(hash-set! *spell-dictionary* "aqueuq" "acidic")
(hash-set! *spell-dictionary* "bcandusahp" "breath")
(hash-set! *spell-dictionary* "bragh" "blast")
(hash-set! *spell-dictionary* "candusqarr" "recoil")
(hash-set! *spell-dictionary* "eugwuggar" "dismissal")
(hash-set! *spell-dictionary* "ghcandusaw" "stream")
(hash-set! *spell-dictionary* "gpaszgpuyh" "shapeshift")
(hash-set! *spell-dictionary* "gqarzg" "scales")
(hash-set! *spell-dictionary* "hiqahz" "locate")
(hash-set! *spell-dictionary* "hpkadawahjfouq" "thaumaturgic")
(hash-set! *spell-dictionary* "hxzrzz" "twelve")
(hash-set! *spell-dictionary* "iaza" "nova")
(hash-set! *spell-dictionary* "izjfahiouqar" "neurological")
(hash-set! *spell-dictionary* "jiyajudig" "unfocused")
(hash-set! *spell-dictionary* "ocandusagz" "grease")
(hash-set! *spell-dictionary* "oculoayunso" "deafen")
(hash-set! *spell-dictionary* "oculoqarquyl" "decalcify")
(hash-set! *spell-dictionary* "oculozur" "devil")
(hash-set! *spell-dictionary* "ouaih" "giant")
(hash-set! *spell-dictionary* "paghz" "haste")
(hash-set! *spell-dictionary* "pzah" "heat")
(hash-set! *spell-dictionary* "qafsacandusar" "corporeal")
(hash-set! *spell-dictionary* "qaiqzrrahuai" "cancellation")
(hash-set! *spell-dictionary* "qaiyjcandus" "conjure")
(hash-set! *spell-dictionary* "qpaiizr" "channel")
(hash-set! *spell-dictionary* "qpaui" "chain")
(hash-set! *spell-dictionary* "qzrzghuar" "celestial")
(hash-set! *spell-dictionary* "ruzuio" "living")
(hash-set! *spell-dictionary* "saguhuzz" "positive")
(hash-set! *spell-dictionary* "sraiabra" "planar")
(hash-set! *spell-dictionary* "sraojz" "plague")
(hash-set! *spell-dictionary* "tkadabfug" "kaubris")
(hash-set! *spell-dictionary* "uiygruzuguai" "infravision")
(hash-set! *spell-dictionary* "uizug" "invis")
(hash-set! *spell-dictionary* "unsopaiqzwunsoh" "enhancement")
(hash-set! *spell-dictionary* "waouq" "magic")
(hash-set! *spell-dictionary* "waraugz" "malaise")
(hash-set! *spell-dictionary* "wugrzae" "mislead")
(hash-set! *spell-dictionary* "wunsohar" "mental")
(hash-set! *spell-dictionary* "wzhabaruq" "metabolic")
(hash-set! *spell-dictionary* "xarr" "will")
(hash-set! *spell-dictionary* "xzatunso" "weaken")
(hash-set! *spell-dictionary* "yarh" "jolt")
(hash-set! *spell-dictionary* "yawuruabra" "familiar")
(hash-set! *spell-dictionary* "yazfuz" "faerie")
(hash-set! *spell-dictionary* "yragp" "flesh")
(hash-set! *spell-dictionary* "yrawzg" "flames")
(hash-set! *spell-dictionary* "zawsufuq" "vampiric")
(hash-set! *spell-dictionary* "zrzwunsohar" "elemental")
(hash-set! *spell-dictionary* "zuculaaruq" "vitriolic")
(hash-set! *spell-dictionary* "zzggag" "vessas")


(defun spell-echo (msg)
  "Echo a spell translator status message to the terminal."
  (terminal-echo (concat "\r\n\033[36m[🔮 Spells]\033[0m " msg "\r\n")))

;; Add a known spell word (skips translation when seen)
(defun spell-add-known (word)
  "Add a known spell word: (spell-add-known \"word\")"
  (set! *known-spell-words* (cons word *known-spell-words*))
  (spell-echo (concat "Added known word: " word))
  word)

;; Remove a known spell word
(defun spell-remove-known (word)
  "Remove a known spell word: (spell-remove-known \"word\")"
  (let ((before (length *known-spell-words*)))
    (set! *known-spell-words*
     (filter (lambda (w) (not (string=? w word))) *known-spell-words*))
    (if (< (length *known-spell-words*) before)
      (spell-echo (concat "Removed known word: " word))
      (spell-echo (concat "Not found: " word)))
    word))

;; Add a custom word override
(defun spell-add (garbled correct)
  "Add a dictionary override: (spell-add \"garbled\" \"correct\")"
  (hash-set! *spell-dictionary* garbled correct)
  (spell-echo (concat "Added: " garbled " -> " correct))
  correct)

;; Remove a word override
(defun spell-remove (garbled)
  "Remove a dictionary override"
  (hash-remove! *spell-dictionary* garbled))

;;; ============================================================================
;;; Translation Functions
;;; ============================================================================
;; Translate a single character using the reverse cipher
(defun translate-garbled-char (c)
  "Translate a single garbled character to original"
  (let ((pair (assoc c *spell-reverse-chars*))) (if pair (cdr pair) c))) ; Unknown chars pass through unchanged

;; Helper to recursively search through syllables for a match
(defun try-match-syllable-helper (word-lower i len syllables)
  "Recursively search through syllables for first match"
  (if (null? syllables)
    nil
    (let* ((pair (car syllables))
           (garbled (car pair))
           (original (cdr pair))
           (garbled-len (length garbled)))
      (if
        (and (<= (+ i garbled-len) len)
             (string=? (substring word-lower i (+ i garbled-len)) garbled))
        (cons original garbled-len)
        (try-match-syllable-helper word-lower i len (cdr syllables))))))

;; Try to match a syllable at position i in word-lower
;; Returns (original-text . chars-consumed) or nil if no match
(defun try-match-syllable (word-lower i len)
  "Try to match a syllable pattern at position i"
  (try-match-syllable-helper word-lower i len *spell-reverse-syllables*))

;; Recursive helper for word translation
(defun translate-word-helper (word-lower i len acc)
  "Recursively translate word from position i, accumulating results in acc"
  (if (>= i len)
    ;; Done - reverse and concatenate results
    (apply string-append (reverse acc))
    ;; Try to match syllable first
    (let ((syllable-match (try-match-syllable word-lower i len)))
      (if syllable-match
        ;; Matched a syllable - advance by syllable length
        (translate-word-helper word-lower (+ i (cdr syllable-match)) len
         (cons (car syllable-match) acc))
        ;; No syllable - translate single char
        (let ((c (string-ref word-lower i)))
          (translate-word-helper word-lower (+ i 1) len
           (cons (char->string (translate-garbled-char c)) acc)))))))

;; Translate a single word using greedy syllable matching + char fallback
(defun translate-garbled-word (word)
  "Translate a garbled word to its original form"
  ;; First check dictionary override
  (let ((override (hash-ref *spell-dictionary* word)))
    (if override
      override
      ;; Apply reverse cipher algorithm using recursive helper
      (let ((word-lower (string-downcase word)))
        (translate-word-helper word-lower 0 (length word-lower) '())))))

;; Translate a phrase (multiple words)
(defun translate-garbled-phrase (phrase)
  "Translate a garbled phrase (space-separated words)"
  (let ((words (split phrase " ")))
    (join (map translate-garbled-word words) " ")))

;;; ============================================================================
;;; Filter Hook
;;; ============================================================================
;; Regex pattern for spell utterances
;; Matches: "Name utters the words, 'garbled text'." (with optional trailing whitespace/newlines)
;; Captures: (1) name, (2) garbled text
;; Note: Pattern allows trailing whitespace/newlines after the period to handle real server text
(define *spell-utter-pattern*
  "([A-Za-z' ]+) utters the words, '([^']+)'[.]?\\s*")

;; Muted magic purple color for translations
(define *spell-color* "\033[38;2;147;112;219m")

(define *spell-color-reset* "\033[0m")

;; Per-line filter function (translates a single line)
(defun spell-translate-line (text)
  "Weave spell translation into a single utterance line"
  ;; Strip ANSI codes for matching, but use original text for replacement
  (let* ((clean-text (strip-ansi text))
         (groups (regex-extract *spell-utter-pattern* clean-text)))
    ;; Main logic: check if pattern matched
    (if groups
      ;; Found an utterance - check if it needs translation
      (let ((garbled (string-trim (cadr groups))))
        (if (known-spell? garbled)
          ;; Already readable (same class as caster) - no translation needed
          text
          ;; Garbled text - translate and weave in after the spell
          (let ((translated (translate-garbled-phrase garbled)))
            ;; Skip if translation matches original (already readable)
            (if
              (string=? (string-downcase translated) (string-downcase garbled))
              text
              ;; Replace quote-period (and any trailing whitespace) with quote-space-translation-period
              ;; Pattern captures trailing whitespace/newlines to preserve them
              ;; $1 = captured trailing whitespace (preserved in replacement)
              (let ((replacement
                     (string-append "' " *spell-color* "(" translated ")"
                      *spell-color-reset* ".$1")))
                (let ((result (regex-replace "'\\.(\\s*)" text replacement)))
                  result))))))
      ;; No match - pass through unchanged
      text)))

;; Filter function for telnet-input-transform-hook
;; Splits multi-line chunks so regex-replace can't bleed across lines
(defun spell-translator-filter (text)
  "Weave spell translation into utterance lines (handles multi-line chunks)"
  (let ((lines (split text "\n")))
    (join (map spell-translate-line lines) "\n")))

;;; ============================================================================
;;; Hook Registration
;;; ============================================================================
;; Register the filter hook
(add-hook 'telnet-input-transform-hook 'spell-translator-filter)

;; Startup message
(script-echo "Spell translator active"
 :section
 "Commands
(spell-add \"garbled\" \"correct\")
(spell-remove \"garbled\")
(spell-add-known \"word\")
(spell-remove-known \"word\")"
 :section
 "Data
*spell-dictionary* — garbled word overrides
*known-spell-words* — words that skip translation")
;; tintin-highlights.lisp - Highlight application for TinTin++ emulator
;;
;; Depends on: tintin-state.lisp, tintin-colors.lisp, tintin-patterns.lisp
;;
;; Uses a 4-phase pipeline for nested ANSI support:
;;   1. Parse ANSI - extract codes from line, produce plain text + ansi-map
;;   2. Collect matches - run all highlight regexes on plain text
;;   3. Render - walk char-by-char, highest-priority highlight wins at each pos
;; ============================================================================
;; LINE SPLITTING
;; ============================================================================
;; Split text into lines, preserving line endings
;; Returns list of lines with their line endings intact
(defun tintin-split-lines (text)
  (if (not (string? text))
    '()
    (let ((len (length text))
          (pos 0)
          (line-start 0)
          (lines '()))
      (do ()
        ((>= pos len)
         ;; Add final line if any
         (if (< line-start len)
           (reverse (cons (substring text line-start len) lines))
           (reverse lines)))
        (let ((ch (string-ref text pos)))
          (if (char=? ch #\newline)
            ;; Found line ending - add line including \n
            (progn
              (set! lines (cons (substring text line-start (+ pos 1)) lines))
              (set! pos (+ pos 1))
              (set! line-start pos))
            ;; Regular character - continue
            (set! pos (+ pos 1))))))))

;; ============================================================================
;; ANSI UTILITIES (kept from old implementation)
;; ============================================================================
;; Check if an ANSI sequence is a reset code (\033[0m or \033[m)
(defun tintin-is-reset-code? (seq) (regex-match? "^\033\\[0*m$" seq))

;; Check if an ANSI sequence is an SGR code (ends with 'm')
(defun tintin-is-sgr-code? (seq) (regex-match? "^\033\\[[0-9;]*m$" seq))

;; Character predicates for CSI sequence scanning (used by tintin-parse-ansi).
(defun tintin-ansi-param-char? (c)
  (or (and (char>=? c #\0) (char<=? c #\9)) (char=? c #\;)))

(defun tintin-ansi-terminator-char? (c)
  (or (and (char>=? c #\A) (char<=? c #\Z))
      (and (char>=? c #\a) (char<=? c #\z))))

;; ============================================================================
;; PHASE 1: PARSE ANSI
;; ============================================================================
;; Walk the line, extract ANSI codes into ansi-map, produce plain-text.
;; Returns (plain-text . ansi-map) where ansi-map is a list of
;; (plain-pos . sequence) pairs in order of occurrence.
(defun tintin-parse-ansi (line)
  ;; Single forward pass with an input string port: port-read-char/peek advance
  ;; a byte cursor in O(1), so the whole walk is O(m) (no per-char string-ref
  ;; rescanning). Plain chars go to OUT; valid CSI sequences are recorded in
  ;; ANSI-MAP at the current plain-text position; a malformed ESC[... or a lone
  ;; ESC falls back to plain text, exactly as before.
  (let ((port (open-input-string line))
        (plain-pos 0)
        (ansi-map '())
        (out (open-output-string)))
    (do () ((port-eof? port) (cons (get-output-string out) (reverse ansi-map)))
      (let ((ch (port-read-char port)))
        (if (char=? ch #\escape)
          (let ((nxt (port-peek-char port)))
            (if (and nxt (char=? nxt #\[))
              ;; ESC '[' ... - scan the candidate CSI body by peeking, so the
              ;; char that ends the scan is never consumed.
              (let ((seq (open-output-string))
                    (seq-len 2) ;; ESC + '['
                    (terminated #f)
                    (scanning #t))
                (port-read-char port) ;; consume '['
                (port-write-char seq #\escape)
                (port-write-char seq #\[)
                (do () ((not scanning))
                  (let ((c (port-peek-char port)))
                    (cond
                      ((null? c) (set! scanning #f)) ;; EOF before terminator
                      ((tintin-ansi-param-char? c)
                       (port-read-char port)
                       (port-write-char seq c)
                       (set! seq-len (+ seq-len 1)))
                      ((tintin-ansi-terminator-char? c)
                       (port-read-char port)
                       (port-write-char seq c)
                       (set! seq-len (+ seq-len 1))
                       (set! terminated #t)
                       (set! scanning #f))
                      (#t (set! scanning #f))))) ;; non-CSI char ends the scan
                (if terminated
                  ;; Valid sequence at the current plain-text position
                  (set! ansi-map
                   (cons (cons plain-pos (get-output-string seq)) ansi-map))
                  ;; Malformed - the consumed "ESC[..." becomes plain text; the
                  ;; char that ended the scan stays in the port for next time.
                  (progn (port-write-string out (get-output-string seq))
                    (set! plain-pos (+ plain-pos seq-len)))))
              ;; Lone ESC (next char isn't '[' or we're at EOF) - plain text
              (progn (port-write-char out #\escape)
                (set! plain-pos (+ plain-pos 1)))))
          ;; Regular character
          (progn (port-write-char out ch) (set! plain-pos (+ plain-pos 1))))))))

;; ============================================================================
;; PHASE 2: COLLECT MATCHES
;; ============================================================================
;; Find all positions where a regex matches in plain-text.
;; Returns list of (start . end) pairs.
(defun tintin-find-all-regex-positions (plain-text regex-pattern)
  (let ((matches (regex-find-all regex-pattern plain-text)))
    (if (or (null? matches) (not (list? matches)))
      '()
      ;; Walk through plain-text finding each match's position progressively
      (let ((positions '())
            (search-from 0))
        (do ((remaining matches (cdr remaining)))
          ((null? remaining) (reverse positions))
          (let* ((matched (car remaining))
                 (match-len (length matched)))
            ;; Find this match starting from search-from
            (if (> match-len 0)
              (let ((found-pos
                     (string-index
                      (substring plain-text search-from (length plain-text))
                      matched)))
                (if found-pos
                  (let ((abs-pos (+ search-from found-pos)))
                    (set! positions
                     (cons (cons abs-pos (+ abs-pos match-len)) positions))
                    ;; Advance past this match to find next occurrence
                    (set! search-from (+ abs-pos match-len))))))))))))

;; Collect all highlight match ranges against plain text.
;; sorted-highlights: list of (pattern fg-color bg-color priority)
;; Returns list of (start end ansi-open priority) ranges.
(defun tintin-collect-highlight-matches (plain-text sorted-highlights)
  (let ((all-ranges '()))
    (do ((i 0 (+ i 1))) ((>= i (length sorted-highlights)) all-ranges)
      (let* ((entry (list-ref sorted-highlights i))
             (pattern (car entry))
             (fg-color (cadr entry))
             (bg-color (caddr entry))
             (priority (cadddr entry))
             (regex-pattern
              (or (hash-ref *tintin-pattern-cache* pattern)
                  (let ((computed (tintin-pattern-to-regex pattern)))
                    (hash-set! *tintin-pattern-cache* pattern computed)
                    computed))))
        (if (not (string=? regex-pattern ""))
          ;; Build ANSI open code for this highlight
          (let ((fg-ansi
                 (if fg-color (tintin-parse-color-component fg-color #f) nil))
                (bg-ansi
                 (if bg-color (tintin-parse-color-component bg-color #t) nil)))
            (let ((ansi-open (tintin-build-ansi-code fg-ansi bg-ansi)))
              (if (not (string=? ansi-open ""))
                ;; Find all match positions
                (let ((positions
                       (tintin-find-all-regex-positions plain-text
                        regex-pattern)))
                  (do ((remaining positions (cdr remaining)))
                    ((null? remaining))
                    (let* ((pos-pair (car remaining))
                           (start (car pos-pair))
                           (end (cdr pos-pair)))
                      (set! all-ranges
                       (cons (list start end ansi-open priority) all-ranges)))))))))))))

;; ============================================================================
;; PHASE 3: RENDER
;; ============================================================================
;; Determine the winning highlight at a given plain-text position.
;; match-ranges: list of (start end ansi-open priority)
;; Returns (ansi-open . priority) or nil if no highlight covers this position.
;; Highest priority wins; at same priority, the range that appears first in
;; match-ranges wins (shorter/more-specific patterns sort first due to
;; tintin-insert-by-priority tiebreaker).
(defun tintin-winning-highlight-at (pos match-ranges)
  (let ((best-ansi nil)
        (best-priority -1))
    (do ((remaining match-ranges (cdr remaining)))
      ((null? remaining) (if best-ansi (cons best-ansi best-priority) nil))
      (let* ((range (car remaining))
             (start (car range))
             (end (cadr range))
             (ansi-open (caddr range))
             (priority (cadddr range)))
        (if (and (>= pos start) (< pos end))
          (if (>= priority best-priority)
            (progn (set! best-ansi ansi-open) (set! best-priority priority))))))))

;; Emit the reconstructed server ANSI state (reset + all tracked sequences)
(defun tintin-emit-server-state (server-state)
  (if (null? server-state)
    "\033[0m"
    (let ((result "\033[0m"))
      (do ((remaining server-state (cdr remaining))) ((null? remaining) result)
        (set! result (concat result (car remaining)))))))

;; Get all ANSI sequences from ansi-map at a given plain-text position
;; Returns a list of sequences (may be empty)
(defun tintin-get-ansi-at-pos (pos ansi-map)
  (let ((seqs '()))
    (do ((remaining ansi-map (cdr remaining)))
      ((null? remaining) (reverse seqs))
      (let ((entry (car remaining)))
        (if (= (car entry) pos) (set! seqs (cons (cdr entry) seqs)))))))

;; Update server-state given an ANSI sequence.
;; Reset codes clear the list; SGR codes append.
(defun tintin-update-server-state (server-state seq)
  (if (tintin-is-reset-code? seq)
    '()
    (if (tintin-is-sgr-code? seq)
      (append server-state (list seq))
      ;; Non-SGR code - don't track
      server-state)))

;; Single-pass render: walk plain-text char by char, emitting ANSI transitions.
;; plain-text: string with no ANSI codes
;; ansi-map: list of (plain-pos . sequence)
;; match-ranges: list of (start end ansi-open priority)
;; Returns the fully rendered string with proper ANSI codes.
(defun tintin-render-highlighted-line (plain-text ansi-map match-ranges)
  (let ((len (length plain-text))
        (in (open-input-string plain-text))
        (out (open-output-string))
        (server-state '())
        (current-highlight nil)
        (pos 0))
    (do ()
      ((>= pos len)
       ;; If we're still in a highlight at end, close it and restore server state
       (if current-highlight
         (port-write-string out (tintin-emit-server-state server-state)))
       ;; Emit any trailing ANSI codes at the end position
       (let ((trailing (tintin-get-ansi-at-pos pos ansi-map)))
         (do ((remaining trailing (cdr remaining))) ((null? remaining))
           (let ((seq (car remaining)))
             (set! server-state (tintin-update-server-state server-state seq))
             ;; Always emit trailing codes (they're after all text)
             (port-write-string out seq))))
       (get-output-string out))
      ;; Process any ANSI codes at this position (update server state)
      (let ((ansi-seqs (tintin-get-ansi-at-pos pos ansi-map)))
        (do ((remaining ansi-seqs (cdr remaining))) ((null? remaining))
          (let ((seq (car remaining)))
            (set! server-state (tintin-update-server-state server-state seq))
            ;; Always emit server ANSI (server colors punch through highlights)
            (port-write-string out seq)
            ;; After a server reset inside a highlight, re-apply highlight color
            (if (and current-highlight (tintin-is-reset-code? seq))
              (port-write-string out (car current-highlight))))))
      ;; Determine winning highlight at this position
      (let ((winner (tintin-winning-highlight-at pos match-ranges)))
        (cond
          ;; Case 1: Entering a highlight (was not highlighted, now is)
          ((and winner (not current-highlight)) (set! current-highlight winner)
           (port-write-string out "\033[0m")
           (port-write-string out (car winner)))
          ;; Case 2: Changing highlight (different highlight now wins)
          ((and winner current-highlight
                (not (string=? (car winner) (car current-highlight))))
           (set! current-highlight winner)
           (port-write-string out "\033[0m")
           (port-write-string out (car winner)))
          ;; Case 3: Leaving highlight (was highlighted, now isn't)
          ((and (not winner) current-highlight)
           (port-write-string out (tintin-emit-server-state server-state))
           (set! current-highlight nil))
          ;; Case 4: Same highlight or no highlight - no transition needed
          (#t nil)))
      ;; Emit the character (read sequentially from the port, O(1) per char,
      ;; staying in lock-step with pos)
      (port-write-char out (port-read-char in))
      (set! pos (+ pos 1)))))

;; ============================================================================
;; HIGHLIGHT APPLICATION
;; ============================================================================
;; Apply highlights to a single line using the 4-phase pipeline
(defun tintin-highlight-line (line)
  "Apply all matching highlight patterns to a single line of text.

  Uses a 4-phase pipeline:
  1. Parse ANSI codes out of line into plain-text + ansi-map
  2. Collect all highlight regex matches against plain-text
  3. Render char-by-char with priority-based highlight selection

  ## Parameters
  - `line` - Line of text to highlight (may contain ANSI codes)

  ## Returns
  Line with ANSI color codes applied for all matching patterns."
  (if (or (not (string? line)) (= (hash-count *tintin-highlights*) 0))
    line
    (progn
      ;; Re-sort only if dirty
      (if *tintin-highlights-dirty*
        (progn
          (set! *tintin-sorted-highlights-cache*
           (tintin-sort-highlights-by-priority
            (hash-entries *tintin-highlights*)))
          (set! *tintin-highlights-dirty* #f)))
      ;; Use cached sorted list
      (let ((sorted *tintin-sorted-highlights-cache*))
        ;; Phase 1: Parse ANSI
        (let* ((parsed (tintin-parse-ansi line))
               (plain-text (car parsed))
               (ansi-map (cdr parsed)))
          ;; If plain text is empty, nothing to highlight
          (if (string=? plain-text "")
            line
            ;; Phase 2: Collect all match ranges
            (let ((match-ranges
                   (tintin-collect-highlight-matches plain-text sorted)))
              ;; If no matches, return original line unchanged
              (if (null? match-ranges)
                line
                ;; Phase 3: Render
                (tintin-render-highlighted-line plain-text ansi-map
                 match-ranges)))))))))

;; Main entry point: Apply highlights to incoming text
;; Splits text into lines, highlights each line, returns transformed text
(defun tintin-apply-highlights (text)
  "Apply color highlighting to text based on defined highlight patterns.

  ## Parameters
  - `text` - Text to process (typically server output)

  ## Returns
  Text with ANSI color codes inserted around matching patterns."
  (if (or (not (string? text)) (= (hash-count *tintin-highlights*) 0))
    text
    ;; Split into lines
    (let ((lines (tintin-split-lines text)))
      (if (null? lines)
        text
        ;; Highlight each line
        (let ((highlighted '()))
          (do ((i 0 (+ i 1))) ((>= i (length lines)))
            (let ((line (list-ref lines i)))
              (set! highlighted (cons (tintin-highlight-line line) highlighted))))
          ;; Reverse since we cons'd in reverse order, then join
          (set! highlighted (reverse highlighted))
          (let ((out (open-output-string)))
            (do ((k 0 (+ k 1)))
              ((>= k (length highlighted)) (get-output-string out))
              (port-write-string out (list-ref highlighted k)))))))))

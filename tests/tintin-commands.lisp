;; tintin-commands.lisp - Tests for the command processing pipeline
;;
;; Tests tintin-process-command, tintin-process-input, alias expansion,
;; filter hook integration, # command dispatch, semicolon splitting,
;; and the alias expansion architecture (aliases return expanded text).

(load "tests/test-helpers.lisp")
(defmacro load-system-file (name) `(load (string-append "lisp/contrib/" ,name)))
(load "lisp/contrib/tintin.lisp")
(set! *tintin-speedwalk-enabled* #f) ;; Disable speedwalk to avoid interference

;; Helper: collect terminal-echo output
(define *echoed* '())
(defun terminal-echo (msg)
  (set! *echoed* (append *echoed* (list msg))))

(defun clear-echoed () (set! *echoed* '()))

;; Helper: collect telnet-send output (for hooks/tests that still call it)
(define *telnet-sent* '())
(defun telnet-send (msg)
  (set! *telnet-sent* (append *telnet-sent* (list msg))))

;; Helper: check if any echoed message contains a substring
(defun some-echoed-contains (substr)
  (let ((found #f))
    (do ((remaining *echoed* (cdr remaining)))
        ((or (null? remaining) found) found)
      (if (and (string? (car remaining))
               (string-index (car remaining) substr))
        (set! found #t)))))

;; Helper: reset aliases to clean state
(defun reset-aliases ()
  (set! *tintin-aliases* (make-hash-table))
  (set! *tintin-alias-depth* 0)
  (set! *sent-inputs* '())
  (set! *sent-results* '())
  (set! *telnet-sent* '())
  (clear-echoed))

;; ============================================================================
;; Test 1: Simple alias expansion (returns expanded text)
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "gh" (list "go home"))

(let ((result (tintin-process-command "gh")))
  (assert-equal result "go home" "Simple alias returns expanded text"))

(print "Test 1 passed: simple alias expansion returns expanded text")

;; ============================================================================
;; Test 2: Alias with arguments (%0)
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "say" (list "say %0"))

(let ((result (tintin-process-command "say hello world")))
  (assert-equal result "say hello world" "Alias with %0 returns expanded text"))

(print "Test 2 passed: alias with %0")

;; ============================================================================
;; Test 3: Alias with numbered args (%1, %2)
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "k" (list "kill %1"))

(let ((result (tintin-process-command "k orc")))
  (assert-equal result "kill orc" "Alias with %1 returns expanded text"))

(print "Test 3 passed: alias with numbered args")

;; ============================================================================
;; Test 4: No alias match — pass through to server
;; ============================================================================
(reset-aliases)

(assert-equal (tintin-process-command "look") "look"
  "Non-aliased command passes through")

(print "Test 4 passed: no alias pass-through")

;; ============================================================================
;; Test 5: Alias with semicolons — returns joined parts
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "buff" (list "cast shield;cast armor"))

(let ((result (tintin-process-command "buff")))
  (assert-equal result "cast shield;cast armor"
    "Alias with semicolons returns joined expanded text"))

(print "Test 5 passed: alias with semicolons")

;; ============================================================================
;; Test 6: Nested alias — alias expands to another alias
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "fb" (list "fullbuff"))
(hash-set! *tintin-aliases* "fullbuff" (list "cast shield;cast armor"))

(let ((result (tintin-process-command "fb")))
  ;; fb -> fullbuff -> alias -> cast shield;cast armor
  (assert-equal result "cast shield;cast armor"
    "Nested alias returns fully expanded text"))

(print "Test 6 passed: nested alias expansion")

;; ============================================================================
;; Test 7: # command dispatch from alias expansion
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "makealias" (list "#alias {zz} {sleep}"))

(tintin-process-command "makealias")
;; send-input("#alias {zz} {sleep}") -> hook pipeline -> dispatches #alias
(assert-true (hash-ref *tintin-aliases* "zz")
  "#alias command created the alias via send-input chain")

(print "Test 7 passed: # command in alias")

;; ============================================================================
;; Test 8: Filter hook consumption via send-input
;; ============================================================================
;; An alias expands to a slash command that should be consumed by the filter hook.
(reset-aliases)

(define *slash-consumed* nil)
(defun test-slash-filter (cmd)
  (if (and (> (length cmd) 0) (char=? (string-ref cmd 0) #\/))
    (progn
      (set! *slash-consumed* cmd)
      nil) ;; consume
    cmd)) ;; pass through

(add-hook 'user-input-hook 'test-slash-filter)

;; Alias that expands to a slash command
(hash-set! *tintin-aliases* "gr" (list "/greet %0"))

(set! *slash-consumed* nil)
(tintin-process-command "gr all")
;; send-input("/greet all") -> filter hook consumes it
(assert-equal *slash-consumed* "/greet all"
  "Filter hook saw the expanded /greet all command via send-input")

(remove-hook 'user-input-hook 'test-slash-filter)

(print "Test 8 passed: filter hook consumes slash command from alias via send-input")

;; ============================================================================
;; Test 9: Filter hook consumption in semicolon-split alias
;; ============================================================================
(reset-aliases)

(define *filter-seen* '())
(defun test-multi-filter (cmd)
  (set! *filter-seen* (append *filter-seen* (list cmd)))
  (if (and (> (length cmd) 0) (char=? (string-ref cmd 0) #\/))
    nil ;; consume slash commands
    cmd)) ;; pass through

(add-hook 'user-input-hook 'test-multi-filter)

;; Alias with mix of server command and slash command
(hash-set! *tintin-aliases* "combo" (list "look;/greet room"))

(set! *filter-seen* '())
(tintin-process-command "combo")
;; send-input("look") -> passes filter, goes to transform hook -> sent
;; send-input("/greet room") -> consumed by filter
(assert-true (member? "/greet room" *filter-seen*)
  "Filter hook saw /greet room from semicolon split via send-input")

(remove-hook 'user-input-hook 'test-multi-filter)

(print "Test 9 passed: filter hook in semicolon-split alias via send-input")

;; ============================================================================
;; Test 10: # command in semicolon-split alias
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "setup" (list "look;#echo {Ready}"))

(let ((result (tintin-process-command "setup")))
  ;; "look" returned as expanded text, "#echo {Ready}" dispatched internally
  (assert-equal result "look" "look returned as expanded text")
  ;; Only server-bound commands are echoed — #commands are not
  ;; (the "Unknown command" error echo is separate from command echo)
  (assert-false (some-echoed-contains "#echo {Ready}\r\n")
    "# commands not echoed as raw command text"))

(print "Test 10 passed: # command in semicolon-split alias")

;; ============================================================================
;; Test 11: tintin-process-input splits top-level semicolons
;; ============================================================================
(reset-aliases)

(let ((result (tintin-process-input "north;south")))
  (assert-equal result "north;south"
    "process-input joins multiple commands with semicolons"))

(print "Test 11 passed: process-input semicolon splitting")

;; ============================================================================
;; Test 12: Circular alias detection (depth limit)
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "loop1" (list "loop2"))
(hash-set! *tintin-aliases* "loop2" (list "loop1"))

(set! *tintin-alias-depth* 0)
(tintin-process-command "loop1")
;; loop1 -> send-input("loop2") (depth=1) -> send-input("loop1") (depth=2) -> ...
;; Eventually hits *tintin-max-alias-depth* and stops
(assert-true (some-echoed-contains "Circular alias")
  "Circular alias error message displayed")

(print "Test 12 passed: circular alias detection")

;; ============================================================================
;; Test 13: Empty and nil inputs
;; ============================================================================
(assert-equal (tintin-process-command "") "" "Empty string returns empty")
(assert-equal (tintin-process-command nil) "" "nil returns empty")

(print "Test 13 passed: empty/nil inputs")

;; ============================================================================
;; Test 14: tintin-try-alias returns nil on no match, string on match
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "zz" (list "sleep"))

(assert-nil (tintin-try-alias "unknown") "tintin-try-alias returns nil for no match")
(assert-equal (tintin-try-alias "zz") "sleep" "tintin-try-alias returns template on match")

(print "Test 14 passed: tintin-try-alias pure function")

;; ============================================================================
;; Test 15: Filter hook at depth 0 (run-filter-hook called for non-alias too)
;; ============================================================================
(reset-aliases)

(define *depth0-filtered* nil)
(defun test-depth0-filter (cmd)
  (if (string=? cmd "blocked")
    (progn (set! *depth0-filtered* #t) nil)
    cmd))

(add-hook 'user-input-hook 'test-depth0-filter)

(set! *depth0-filtered* nil)
(let ((result (tintin-process-command "blocked")))
  (assert-equal result "" "Filter hook consumes at depth 0")
  (assert-true *depth0-filtered* "Filter hook was called at depth 0"))

(set! *depth0-filtered* nil)
(let ((result (tintin-process-command "allowed")))
  (assert-equal result "allowed" "Non-blocked command passes through at depth 0")
  (assert-false *depth0-filtered* "Filter hook did not consume allowed command"))

(remove-hook 'user-input-hook 'test-depth0-filter)

(print "Test 15 passed: filter hook at depth 0")

;; ============================================================================
;; Test 16: Pattern alias with wildcards
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "cast %1 at %2" (list "cast '%1' target '%2'"))

(let ((result (tintin-process-command "cast fireball at dragon")))
  (assert-equal result "cast 'fireball' target 'dragon'"
    "Pattern alias with wildcards returns expanded text"))

(print "Test 16 passed: pattern alias with wildcards")

;; ============================================================================
;; Test 17: Self-referencing alias stops at depth limit
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "x" (list "x"))

(set! *tintin-alias-depth* 0)
(tintin-process-command "x")
(assert-true (some-echoed-contains "Circular alias")
  "Self-referencing alias stops at depth limit")

(print "Test 17 passed: self-referencing alias")

;; ============================================================================
;; Test 18: Fork-bomb alias stops at depth limit
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "bomb" (list "bomb;bomb"))

(set! *tintin-alias-depth* 0)
(tintin-process-command "bomb")
(assert-true (some-echoed-contains "Circular alias")
  "Fork-bomb alias stops at depth limit")

(print "Test 18 passed: fork-bomb alias")

;; ============================================================================
;; Test 19: Depth resets on fresh input
;; ============================================================================
;; After circular alias test, depth is at max.
;; Simulate fresh input by resetting (what process_line does in C)
(set! *tintin-alias-depth* 0)
(tintin-process-command "look")
(assert-equal *tintin-alias-depth* 0
  "Non-alias command doesn't increment depth")

(print "Test 19 passed: depth resets on fresh input")

;; ============================================================================
;; Test 20: Alias with multiple parts returns all siblings
;; ============================================================================
(reset-aliases)
(hash-set! *tintin-aliases* "tri" (list "a;b;c"))

(set! *tintin-alias-depth* 0)
(let ((result (tintin-process-command "tri")))
  ;; 3 sibling parts all process at depth 1 (same nesting level)
  (assert-equal result "a;b;c" "All siblings returned joined"))

(print "Test 20 passed: alias siblings all returned")

;; ============================================================================
;; Test 21: Nested alias depth-first ordering (returned in order)
;; ============================================================================
;; When ef -> "gb lamb;eat lamb" and gb -> "get %1 bag", depth-first means
;; "get lamb bag" must appear before "eat lamb" in the result.
(reset-aliases)

(hash-set! *tintin-aliases* "gb" (list "get %1 bag"))
(hash-set! *tintin-aliases* "ef" (list "gb lamb;eat lamb"))

(let ((result (tintin-process-command "ef")))
  (assert-equal result "get lamb bag;eat lamb"
    "Depth-first: nested alias returns commands in correct order"))

(print "Test 21 passed: nested alias depth-first ordering")

;; ============================================================================
;; Test 22: #color command - set custom color
;; ============================================================================
(reset-aliases)
(set! *tintin-custom-colors* (make-hash-table))
(clear-echoed)

(tintin-process-command "#color {failure} {<Fff6daa>}")
(assert-equal (hash-ref *tintin-custom-colors* "failure") "<Fff6daa>"
  "#color sets custom color in hash table")
(assert-true (some-echoed-contains "Color 'failure' set to")
  "#color echoes confirmation")

(print "Test 22 passed: #color set custom color")

;; ============================================================================
;; Test 23: #color command - show specific color
;; ============================================================================
(clear-echoed)
(tintin-process-command "#color {failure}")
(assert-true (some-echoed-contains "Color 'failure'")
  "#color with one arg shows the color")

(print "Test 23 passed: #color show specific color")

;; ============================================================================
;; Test 24: #color command - list all (no args)
;; ============================================================================
(hash-set! *tintin-custom-colors* "success" "<F00ffb2>")
(clear-echoed)
(tintin-process-command "#color")
(assert-true (some-echoed-contains "Colors (")
  "#color with no args lists all colors")

(print "Test 24 passed: #color list all")

;; ============================================================================
;; Test 25: #uncolor command - remove custom color
;; ============================================================================
(clear-echoed)
(tintin-process-command "#uncolor {failure}")
(assert-nil (hash-ref *tintin-custom-colors* "failure")
  "#uncolor removes custom color")
(assert-true (some-echoed-contains "removed")
  "#uncolor echoes confirmation")

(print "Test 25 passed: #uncolor remove custom color")

;; ============================================================================
;; Test 26: #uncolor command - non-existent color
;; ============================================================================
(clear-echoed)
(tintin-process-command "#uncolor {nonexistent}")
(assert-true (some-echoed-contains "not found")
  "#uncolor on missing color reports not found")

(print "Test 26 passed: #uncolor non-existent")

;; ============================================================================
;; Test 27: #write/#read round-trip (TinTin++ syntax)
;; ============================================================================
(set! *tintin-custom-colors* (make-hash-table))
(hash-set! *tintin-custom-colors* "danger" "bold <Ffe3e78>")
(hash-set! *tintin-custom-colors* "info" "bold <Fff6dff>")
(set! *tintin-aliases* (make-hash-table))
(hash-set! *tintin-aliases* "k" (list "kill %0" 5))
(hash-set! *tintin-aliases* "h" (list "hit $target" 5))
(set! *tintin-variables* (make-hash-table))
(hash-set! *tintin-variables* "target" "goblin")
(set! *tintin-highlights* (make-hash-table))
(hash-set! *tintin-highlights* "You%* fail%*" (list "<Fff6daa>" nil 5))
(hash-set! *tintin-highlights* "^%* screams%*" (list "bold red" "blue" 5))
(set! *tintin-actions* (make-hash-table))
(hash-set! *tintin-actions* "%0 arrives." (list "look" 5))
(hash-set! *tintin-actions* "%0 drops %1" (list "get %1" 3))
(set! *tintin-speedwalk-enabled* #t)
(set! *tintin-speedwalk-diagonals* #f)

;; Write state to file in TinTin++ syntax
(tintin-save-state "/tmp/bloom-test-write.tin")

;; Clear all state
(set! *tintin-custom-colors* (make-hash-table))
(set! *tintin-aliases* (make-hash-table))
(set! *tintin-variables* (make-hash-table))
(set! *tintin-highlights* (make-hash-table))
(set! *tintin-actions* (make-hash-table))

;; Read it back via tintin-read-file (TinTin++ parser)
(tintin-read-file "/tmp/bloom-test-write.tin")

;; Verify colors
(assert-equal (hash-ref *tintin-custom-colors* "danger") "bold <Ffe3e78>"
  "#write round-trip preserves 'danger' color")
(assert-equal (hash-ref *tintin-custom-colors* "info") "bold <Fff6dff>"
  "#write round-trip preserves 'info' color")

;; Verify aliases
(let ((alias-data (hash-ref *tintin-aliases* "k")))
  (assert-equal (car alias-data) "kill %0"
    "#write round-trip preserves alias 'k'"))

;; Verify variables
(assert-equal (hash-ref *tintin-variables* "target") "goblin"
  "#write round-trip preserves variable 'target'")

;; Verify highlights
(let ((hl-data (hash-ref *tintin-highlights* "You%* fail%*")))
  (assert-equal (car hl-data) "<Fff6daa>"
    "#write round-trip preserves highlight fg color"))
(let ((hl-data (hash-ref *tintin-highlights* "^%* screams%*")))
  (assert-equal (car hl-data) "bold red"
    "#write round-trip preserves highlight with fg:bg (fg)")
  (assert-equal (cadr hl-data) "blue"
    "#write round-trip preserves highlight with fg:bg (bg)"))

;; Verify actions
(let ((act-data (hash-ref *tintin-actions* "%0 arrives.")))
  (assert-equal (car act-data) "look"
    "#write round-trip preserves action"))
(let ((act-data (hash-ref *tintin-actions* "%0 drops %1")))
  (assert-equal (car act-data) "get %1"
    "#write round-trip preserves action with priority")
  (assert-equal (cadr act-data) 3
    "#write round-trip preserves non-default priority"))

;; Verify settings
(assert-true *tintin-speedwalk-enabled*
  "#write round-trip preserves speedwalk on")
(assert-false *tintin-speedwalk-diagonals*
  "#write round-trip preserves speedwalk diagonals off")

(print "Test 27 passed: #write/#read round-trip")

;; ============================================================================
;; Test 28: #config command - list settings
;; ============================================================================
(clear-echoed)
(set! *tintin-speedwalk-enabled* #t)
(set! *tintin-speedwalk-diagonals* #f)
(tintin-process-command "#config")
(assert-true (some-echoed-contains "speedwalk")
  "#config lists speedwalk setting")

(print "Test 28 passed: #config list settings")

;; ============================================================================
;; Test 29: #config command - show specific setting
;; ============================================================================
(clear-echoed)
(tintin-process-command "#config {speedwalk}")
(assert-true (some-echoed-contains "on")
  "#config {speedwalk} shows current value")

(print "Test 29 passed: #config show setting")

;; ============================================================================
;; Test 30: #config command - set on/off
;; ============================================================================
(clear-echoed)
(tintin-process-command "#config {speedwalk} {off}")
(assert-false *tintin-speedwalk-enabled*
  "#config {speedwalk} {off} disables speedwalk")

(tintin-process-command "#config {speedwalk} {on}")
(assert-true *tintin-speedwalk-enabled*
  "#config {speedwalk} {on} enables speedwalk")

(print "Test 30 passed: #config set on/off")

;; ============================================================================
;; Test 31: #config command - speedwalk diagonals
;; ============================================================================
(clear-echoed)
(tintin-process-command "#config {speedwalk diagonals} {on}")
(assert-true *tintin-speedwalk-diagonals*
  "#config {speedwalk diagonals} {on} enables diagonals")

(tintin-process-command "#config {speedwalk diagonals} {off}")
(assert-false *tintin-speedwalk-diagonals*
  "#config {speedwalk diagonals} {off} disables diagonals")

(print "Test 31 passed: #config speedwalk diagonals")

;; ============================================================================
;; Test 32: tintin-echo and tintin-error-echo styling
;; ============================================================================
(reset-aliases)
(tintin-echo "hello")
(assert-true (some-echoed-contains "[🐈 Tintin]") "tintin-echo includes tag")
(assert-true (some-echoed-contains "\033[36m") "tintin-echo uses cyan")
(assert-true (some-echoed-contains "hello") "tintin-echo includes message")

(reset-aliases)
(tintin-error-echo "oops")
(assert-true (some-echoed-contains "[🐈 Tintin]") "tintin-error-echo includes tag")
(assert-true (some-echoed-contains "\033[31m") "tintin-error-echo uses red")
(assert-true (some-echoed-contains "oops") "tintin-error-echo includes message")

(print "Test 32 passed: tintin-echo / tintin-error-echo styling")

;; ============================================================================
;; Test 33: unclosed brace surfaces a red parse error (no alias fallthrough)
;; ============================================================================
(reset-aliases)
(tintin-process-command "#alias a {/scan all {bad")
(assert-true (some-echoed-contains "unclosed brace")
 "unclosed-brace dispatch echoes 'unclosed brace'")
(assert-true (some-echoed-contains "\033[31m")
 "unclosed-brace dispatch echoes in red")
(assert-false (some-echoed-contains "Alias 'a")
 "unclosed-brace dispatch does NOT fall through to alias lookup")

;; Valid alias still creates (no regression)
(reset-aliases)
(tintin-process-command "#alias b {kill orc}")
(assert-true (some-echoed-contains "Alias 'b' created")
 "valid alias still creates")

(print "Test 33 passed: unclosed-brace dispatch")

;; Cleanup
(set! *tintin-custom-colors* (make-hash-table))
(set! *tintin-aliases* (make-hash-table))
(set! *tintin-variables* (make-hash-table))
(set! *tintin-highlights* (make-hash-table))
(set! *tintin-actions* (make-hash-table))
(set! *tintin-speedwalk-enabled* #t)
(set! *tintin-speedwalk-diagonals* #f)

(print "")
(print "All command processing tests passed!")

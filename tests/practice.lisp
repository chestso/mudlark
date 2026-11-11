;; tests/practice.lisp - Tests for practice mode
(load "tests/test-helpers.lisp")

;; Load practice.lisp (will use our mocks)
(load "lisp/contrib/practice.lisp")

;; Retry patterns have no defaults any more — they are user configuration.
;; Register the messages the hook is driven with below.
(practice-add-retry-pattern "You failed.")
(practice-add-retry-pattern "You lost your concentration.")

;; ============================================================================
;; practice-send - delegates to send-input
;; ============================================================================

;; Single command
(set! *sent-inputs* '())
(practice-send "cast fireball")
(assert-equal *sent-inputs* '("cast fireball")
  "practice-send passes command to send-input")

;; Multiline command (semicolons preserved for input pipeline to handle)
(set! *sent-inputs* '())
(practice-send "cast heal;cast armor")
(assert-equal *sent-inputs* '("cast heal;cast armor")
  "practice-send preserves semicolons for input pipeline")

;; ============================================================================
;; practice-parse-commands - splitting on |
;; ============================================================================

(assert-equal (practice-parse-commands "cast fireball") '("cast fireball")
  "Single command parsed into one-element list")

(assert-equal (practice-parse-commands "dash east look | dash west look")
  '("dash east look" "dash west look")
  "Pipe-delimited commands parsed and trimmed")

(assert-equal (practice-parse-commands "  cast heal  |  cast armor  ")
  '("cast heal" "cast armor")
  "Extra whitespace trimmed from both commands")

(assert-equal (practice-parse-commands "a|b|c") '("a" "b" "c")
  "Three commands parsed")

;; ============================================================================
;; Single command - backward compatibility
;; ============================================================================

;; Reset state
(set! *practice-mode* nil)
(set! *practice-command* nil)
(set! *practice-command-index* 0)
(set! *sent-inputs* '())

(practice-start "cast fireball")
(assert-true *practice-mode* "practice-start activates practice mode")
(assert-equal *practice-command* '("cast fireball")
  "Single command stored as one-element list")
(assert-equal (car *sent-inputs*) "cast fireball"
  "First send is the command")

;; Simulate retry - should re-send same command
(set! *sent-inputs* '())
(practice-telnet-hook "You failed.")
(assert-equal (car *sent-inputs*) "cast fireball"
  "Retry sends the single command again")

;; Clean up
(practice-stop)

;; ============================================================================
;; Alternating commands
;; ============================================================================

(set! *practice-mode* nil)
(set! *practice-command* nil)
(set! *practice-command-index* 0)
(set! *sent-inputs* '())

(practice-start "dash east look | dash west look")
(assert-true *practice-mode* "alternating: practice mode active")
(assert-equal *practice-command* '("dash east look" "dash west look")
  "alternating: both commands stored")
(assert-equal (car *sent-inputs*) "dash east look"
  "alternating: first send is command A")
(assert-equal *practice-command-index* 1
  "alternating: index advanced to 1 after first send")

;; Simulate retry - sends current command (B), then advances to A
(set! *sent-inputs* '())
(practice-telnet-hook "You failed.")
(assert-equal (car *sent-inputs*) "dash west look"
  "alternating: retry sends command B")
(assert-equal *practice-command-index* 0
  "alternating: index wraps back to 0")

;; Another retry - sends A again, advances to B
(set! *sent-inputs* '())
(practice-telnet-hook "You lost your concentration.")
(assert-equal (car *sent-inputs*) "dash east look"
  "alternating: retry sends command A again")
(assert-equal *practice-command-index* 1
  "alternating: index advances to 1")

;; Clean up
(practice-stop)
(assert-equal *practice-command-index* 0
  "stop resets command index to 0")

;; ============================================================================
;; Sleep/wake with alternating commands
;; ============================================================================

(set! *practice-mode* nil)
(set! *practice-command* nil)
(set! *practice-command-index* 0)
(set! *sent-inputs* '())

(practice-start "dash east look | dash west look")
;; Index is now 1 (advanced after sending A)

;; Trigger retry to send B, index becomes 0
(practice-telnet-hook "You failed.")
(assert-equal *practice-command-index* 0
  "sleep-wake: index at 0 before sleep")

;; Enter sleep
(set! *sent-inputs* '())
(practice-telnet-hook "You don't have enough mana.")
(assert-true *practice-sleep-mode* "sleep-wake: entered sleep mode")

;; Wake up (100% mana in prompt)
(set! *sent-inputs* '())
(practice-telnet-hook "100%h 100%m 100%v")
(assert-false *practice-sleep-mode* "sleep-wake: exited sleep mode")
;; Should have sent "stand" then current command (A at index 0)
(assert-equal (list-ref *sent-inputs* 0) "stand"
  "sleep-wake: sends stand first")
(assert-equal (list-ref *sent-inputs* 1) "dash east look"
  "sleep-wake: resumes with current command A")
(assert-equal *practice-command-index* 1
  "sleep-wake: index advanced after wake send")

(practice-stop)

;; ============================================================================
;; Retry pattern management via slash command
;; ============================================================================

;; Save original patterns
(define *original-patterns* *practice-retry-patterns*)

;; Add a new pattern
(practice-handler "add You stumble")
(assert-true (member "You stumble" *practice-retry-patterns*)
  "slash add: pattern added")

;; Adding duplicate doesn't duplicate
(define *count-before* (length *practice-retry-patterns*))
(practice-handler "add You stumble")
(assert-equal (length *practice-retry-patterns*) *count-before*
  "slash add: duplicate not added")

;; Remove a pattern
(practice-handler "remove You stumble")
(assert-false (member "You stumble" *practice-retry-patterns*)
  "slash remove: pattern removed")

;; Remove non-existent pattern doesn't error
(practice-handler "remove nonexistent pattern")

;; List patterns (just verify it doesn't error)
(practice-handler "patterns")

;; Restore original patterns
(set! *practice-retry-patterns* *original-patterns*)

;; ============================================================================
;; Status display with alternating commands
;; ============================================================================

(set! *practice-mode* nil)
(set! *practice-command* nil)
(set! *practice-command-index* 0)
(set! *sent-inputs* '())

(practice-start "cast fireball | cast icebolt")
;; Status check - just verify it doesn't error
(practice-handler "")
(practice-stop)

;; ============================================================================
;; Already practicing guard
;; ============================================================================

(set! *practice-mode* nil)
(set! *sent-inputs* '())
(practice-start "cast fireball | cast icebolt")
;; Try to start again - should show message, not start
(define *count-before* (length *sent-inputs*))
(practice-start "cast heal")
(assert-equal (length *sent-inputs*) *count-before*
  "already-practicing: second start doesn't send")
(practice-stop)

(print "All practice.lisp tests passed!")

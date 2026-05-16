;; Tests for status mode registry Lisp API (init.lisp)
;; Run with: ./tests/run-test.sh tests/status.lisp

(load "tests/test-helpers.lisp")

;; ============================================================================
;; Override C builtin mocks with capturing versions for testing
;; ============================================================================
(defvar *status-text* "" "Captured composed status text from set-status")

(defun set-status (&optional text)
  "Mock raw C API: capture status text"
  (set! *status-text* (if text text ""))
  nil)

;; ============================================================================
;; Load init.lisp to get Lisp-side status functions
;; ============================================================================
(load "lisp/init.lisp")

;; Helper to reset registry state between tests
(defun reset-status-state ()
  (set! *status-mode-registry* '())
  (set! *status-text* ""))

;; ============================================================================
;; Test: status--insert-sorted helper function
;; ============================================================================
(print "Testing status--insert-sorted...")

;; Insert into empty list
(assert-equal (status--insert-sorted '(a "A" 50) '())
              '((a "A" 50))
              "Insert into empty list")

;; Insert higher priority at front
(assert-equal (status--insert-sorted '(b "B" 100) '((a "A" 50)))
              '((b "B" 100) (a "A" 50))
              "Higher priority inserted at front")

;; Insert lower priority at end
(assert-equal (status--insert-sorted '(c "C" 25) '((a "A" 50)))
              '((a "A" 50) (c "C" 25))
              "Lower priority inserted at end")

;; Insert middle priority in correct position
(assert-equal (status--insert-sorted '(b "B" 75) '((a "A" 100) (c "C" 50)))
              '((a "A" 100) (b "B" 75) (c "C" 50))
              "Middle priority inserted in correct position")

;; Equal priority: new item goes after existing (stable insert)
(assert-equal (status--insert-sorted '(b "B" 50) '((a "A" 50)))
              '((a "A" 50) (b "B" 50))
              "Equal priority: new item after existing")

(print "status--insert-sorted tests passed!")

;; ============================================================================
;; Test: status--compose-modes helper function
;; ============================================================================
(print "Testing status--compose-modes...")

(reset-status-state)

;; Empty registry clears status
(status--compose-modes)
(assert-equal *status-text* "" "Empty registry clears status")

;; Single entry
(set! *status-mode-registry* '((a "AAA" 50)))
(status--compose-modes)
(assert-equal *status-text* "AAA" "Single entry composed")

;; Multiple entries joined with separator
(set! *status-mode-registry* '((b "BBB" 100) (a "AAA" 50)))
(status--compose-modes)
(assert-equal *status-text* "BBB · AAA" "Multiple entries joined")

;; Three entries
(set! *status-mode-registry* '((c "CCC" 150) (b "BBB" 100) (a "AAA" 50)))
(status--compose-modes)
(assert-equal *status-text* "CCC · BBB · AAA" "Three entries joined")

(print "status--compose-modes tests passed!")

;; ============================================================================
;; Test: status-mode-set
;; ============================================================================
(print "Testing status-mode-set...")

(reset-status-state)

;; Add first mode
(status-mode-set 'mode-a "Mode A" 50)
(assert-equal *status-text* "Mode A" "First mode added")
(assert-equal (length *status-mode-registry*) 1 "Registry has 1 entry")

;; Add higher priority mode
(status-mode-set 'mode-b "Mode B" 100)
(assert-equal *status-text* "Mode B · Mode A" "Higher priority at front")
(assert-equal (length *status-mode-registry*) 2 "Registry has 2 entries")

;; Add lower priority mode
(status-mode-set 'mode-c "Mode C" 25)
(assert-equal *status-text* "Mode B · Mode A · Mode C" "Lower priority at end")
(assert-equal (length *status-mode-registry*) 3 "Registry has 3 entries")

;; Update existing mode text (same priority)
(status-mode-set 'mode-a "Updated A" 50)
(assert-equal *status-text* "Mode B · Updated A · Mode C" "Text updated, position same")
(assert-equal (length *status-mode-registry*) 3 "Registry still has 3 entries")

;; Update existing mode priority (moves position)
(status-mode-set 'mode-c "Mode C" 200)
(assert-equal *status-text* "Mode C · Mode B · Updated A" "Priority update moves position")
(assert-equal (length *status-mode-registry*) 3 "Registry still has 3 entries")

;; Update both text and priority
(status-mode-set 'mode-a "New A" 150)
(assert-equal *status-text* "Mode C · New A · Mode B" "Both text and priority updated")

(print "status-mode-set tests passed!")

;; ============================================================================
;; Test: status-mode-remove
;; ============================================================================
(print "Testing status-mode-remove...")

(reset-status-state)

;; Setup: add three modes
(status-mode-set 'x "X" 100)
(status-mode-set 'y "Y" 50)
(status-mode-set 'z "Z" 25)
(assert-equal *status-text* "X · Y · Z" "Initial state")

;; Remove middle
(status-mode-remove 'y)
(assert-equal *status-text* "X · Z" "Middle removed")
(assert-equal (length *status-mode-registry*) 2 "Registry has 2 entries")

;; Remove first (highest priority)
(status-mode-remove 'x)
(assert-equal *status-text* "Z" "First removed")
(assert-equal (length *status-mode-registry*) 1 "Registry has 1 entry")

;; Remove last
(status-mode-remove 'z)
(assert-equal *status-text* "" "Last removed, status cleared")
(assert-equal (length *status-mode-registry*) 0 "Registry is empty")

;; Remove non-existent (no-op)
(status-mode-remove 'nonexistent)
(assert-equal *status-text* "" "Remove non-existent is no-op")
(assert-equal (length *status-mode-registry*) 0 "Registry still empty")

;; Remove from empty registry (no-op)
(status-mode-remove 'anything)
(assert-equal *status-text* "" "Remove from empty is no-op")

(print "status-mode-remove tests passed!")

;; ============================================================================
;; Test: Edge cases
;; ============================================================================
(print "Testing edge cases...")

(reset-status-state)

;; Empty text
(status-mode-set 'empty "" 50)
(assert-equal *status-text* "" "Empty text mode")

;; Negative priority
(status-mode-set 'neg "Negative" -100)
(assert-equal *status-text* " · Negative" "Negative priority works")

(reset-status-state)

;; Zero priority
(status-mode-set 'zero "Zero" 0)
(status-mode-set 'pos "Positive" 50)
(status-mode-set 'neg "Negative" -50)
(assert-equal *status-text* "Positive · Zero · Negative" "Mixed priorities sorted")

;; Very large priorities
(reset-status-state)
(status-mode-set 'big "Big" 999999)
(status-mode-set 'small "Small" 1)
(assert-equal *status-text* "Big · Small" "Large priority difference")

;; Same symbol added twice (should update, not duplicate)
(reset-status-state)
(status-mode-set 'dup "First" 50)
(status-mode-set 'dup "Second" 50)
(assert-equal (length *status-mode-registry*) 1 "No duplicate entries")
(assert-equal *status-text* "Second" "Second value used")

;; Unicode text
(reset-status-state)
(status-mode-set 'unicode "🔴 Recording" 100)
(assert-equal *status-text* "🔴 Recording" "Unicode in mode text")

(print "Edge case tests passed!")

;; ============================================================================
;; Test: Rapid updates
;; ============================================================================
(print "Testing rapid updates...")

(reset-status-state)

;; Add and remove many modes rapidly
(status-mode-set 'a "A" 10)
(status-mode-set 'b "B" 20)
(status-mode-set 'c "C" 30)
(status-mode-set 'd "D" 40)
(status-mode-set 'e "E" 50)
(assert-equal *status-text* "E · D · C · B · A" "5 modes added")

(status-mode-remove 'c)
(status-mode-remove 'a)
(status-mode-remove 'e)
(assert-equal *status-text* "D · B" "3 modes removed")

(status-mode-set 'f "F" 35)
(assert-equal *status-text* "D · F · B" "New mode inserted in middle")

(print "Rapid update tests passed!")

;; ============================================================================
;; All tests passed
;; ============================================================================
(print "")
(print "All status tests passed!")

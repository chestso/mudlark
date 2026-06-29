;; Session management tests for mudlark
;; Tests session creation, switching, isolation, naming, and destruction.

(load "tests/test-helpers.lisp")

;; ============================================================================
;; Test 1: Default session exists
;; ============================================================================
(assert-equal (telnet-session-current) 1 "Default session id is 1")
(assert-equal (telnet-session-name) "default" "Default session name is 'default'")

;; telnet-session-list should contain exactly the default session
(let ((sessions (telnet-session-list)))
  (assert-true (pair? sessions) "Session list is non-empty")
  (assert-equal (length sessions) 1 "Session list has 1 entry")
  (let ((first (car sessions)))
    (assert-equal (car first) 1 "First session id is 1")
    (assert-equal (cdr first) "default" "First session name is 'default'")))

(print "Test 1 passed: Default session exists")

;; ============================================================================
;; Test 2: Create a second session
;; ============================================================================
(define second-id (telnet-session-create "test-session"))
(assert-true (> second-id 1) "Second session id > 1")

;; Verify it appears in the list
(let ((sessions (telnet-session-list)))
  (assert-equal (length sessions) 2 "Session list has 2 entries after create"))

;; Current session should still be default
(assert-equal (telnet-session-current) 1 "Current session unchanged after create")

;; Check name of new session
(assert-equal (telnet-session-name second-id) "test-session"
  "New session name matches")

(print "Test 2 passed: Create second session")

;; ============================================================================
;; Test 3: Switch sessions and verify isolation
;; ============================================================================

;; Define a variable in the default session
(session-var-set "my-var" "default-value")
(assert-equal (session-var-get "my-var") "default-value"
  "Variable set in default session")

;; Switch to second session
(telnet-session-switch second-id)
(assert-equal (telnet-session-current) second-id "Switched to second session")

;; Variable should not exist in the second session
(assert-nil (session-var-get "my-var")
  "Variable from default not visible in second session")

;; Define the same variable with a different value
(session-var-set "my-var" "test-value")
(assert-equal (session-var-get "my-var") "test-value"
  "Variable set in second session")

;; Switch back to default and verify original value
(telnet-session-switch 1)
(assert-equal (telnet-session-current) 1 "Switched back to default session")
(assert-equal (session-var-get "my-var") "default-value"
  "Default session variable unchanged after switching")

(print "Test 3 passed: Session isolation works")

;; ============================================================================
;; Test 4: Session names
;; ============================================================================
(assert-equal (telnet-session-name) "default" "telnet-session-name with no args = current")
(assert-equal (telnet-session-name 1) "default" "telnet-session-name for id 1")
(assert-equal (telnet-session-name second-id) "test-session"
  "telnet-session-name for second session")
(assert-nil (telnet-session-name 999) "telnet-session-name for nonexistent id returns nil")

(print "Test 4 passed: Session names work")

;; ============================================================================
;; Test 5: Destroy session
;; ============================================================================

;; Cannot destroy current session
(assert-error (telnet-session-destroy 1)
  "Cannot destroy current session")

;; Can destroy other session
(assert-true (telnet-session-destroy second-id) "Destroy second session succeeds")

;; Verify it's gone from the list
(let ((sessions (telnet-session-list)))
  (assert-equal (length sessions) 1 "Session list has 1 entry after destroy"))

;; Cannot destroy already-destroyed session
(assert-error (telnet-session-destroy second-id)
  "Cannot destroy already-destroyed session")

;; Cannot switch to destroyed session
(assert-error (telnet-session-switch second-id)
  "Cannot switch to destroyed session")

(print "Test 5 passed: Session destroy works")

;; ============================================================================
;; Test 6: Create multiple sessions
;; ============================================================================
(define s1 (telnet-session-create "alpha"))
(define s2 (telnet-session-create "beta"))
(define s3 (telnet-session-create "gamma"))

(let ((sessions (telnet-session-list)))
  (assert-equal (length sessions) 4
    "4 sessions total (default + 3 new)"))

;; Clean up
(telnet-session-destroy s1)
(telnet-session-destroy s2)
(telnet-session-destroy s3)

(let ((sessions (telnet-session-list)))
  (assert-equal (length sessions) 1 "Back to 1 session after cleanup"))

(print "Test 6 passed: Multiple session lifecycle")

(print "")
(print "All session tests passed!")

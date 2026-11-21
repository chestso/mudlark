;; Test slash command registration and dispatch system
(load "tests/test-helpers.lisp")
(load "lisp/init.lisp")

;; Override terminal-echo to capture output for testing
(define *terminal-echo-output* '())
(defun terminal-echo (msg)
  (set! *terminal-echo-output* (append *terminal-echo-output* (list msg))))

(defun clear-terminal-output ()
  (set! *terminal-echo-output* '()))

(defun terminal-output-contains? (substr)
  "Check if any terminal-echo output contains the given substring."
  (let ((found #f))
    (do ((msgs *terminal-echo-output* (cdr msgs))) ((or found (null? msgs)) found)
      (when (string-contains? (car msgs) substr)
        (set! found #t)))))

;; ============================================================================
;; Setup: register test commands
;; ============================================================================
(define *test-handler-calls* '())

(defun test-handler-alpha (args)
  (set! *test-handler-calls* (cons (list "alpha" args) *test-handler-calls*)))

(defun test-handler-beta (args)
  (set! *test-handler-calls* (cons (list "beta" args) *test-handler-calls*)))

(clear-terminal-output)
(register-slash-command "/alpha" test-handler-alpha "Alpha command"
 :desc "An alpha test command"
 :usage "/alpha <arg>"
 :config "(alpha-set-foo \"bar\")")

(register-slash-command "/beta" test-handler-beta "Beta command"
 :desc "A beta test command"
 :aliases '("/b"))

;; ============================================================================
;; Test 1: Registration stores entries correctly
;; ============================================================================
(assert-true (hash-ref *slash-commands* "/alpha")
 "Alpha command registered in hash table")

(let ((entry (hash-ref *slash-commands* "/alpha")))
  (assert-equal (list-ref entry 1) "Alpha command" "Title stored correctly")
  (assert-equal (list-ref entry 2) "An alpha test command" "Desc stored correctly")
  (assert-true (pair? (list-ref entry 3)) "Sections stored as list"))

;; ============================================================================
;; Test 2: Lookup by exact name
;; ============================================================================
(assert-equal (slash-command-lookup "/alpha") "/alpha"
 "Exact name lookup works")
(assert-equal (slash-command-lookup "/beta") "/beta"
 "Exact name lookup works for beta")

;; ============================================================================
;; Test 3: Lookup by alias
;; ============================================================================
(assert-equal (slash-command-lookup "/b") "/beta"
 "Alias lookup resolves to canonical name")

;; ============================================================================
;; Test 4: Lookup by prefix
;; ============================================================================
(assert-equal (slash-command-lookup "/alp") "/alpha"
 "Prefix lookup works for /alp -> /alpha")
(assert-equal (slash-command-lookup "/bet") "/beta"
 "Prefix lookup works for /bet -> /beta")

;; ============================================================================
;; Test 5: Ambiguous prefix detection
;; ============================================================================
;; Register another command starting with /al to create ambiguity
(defun test-handler-almanac (args) nil)
(register-slash-command "/almanac" test-handler-almanac "Almanac")

(assert-true (pair? (slash-command-lookup "/al"))
 "Ambiguous prefix returns list for /al (matches /alpha and /almanac)")
;; But /alp still uniquely matches /alpha
(assert-equal (slash-command-lookup "/alp") "/alpha"
 "/alp still uniquely matches /alpha")

;; ============================================================================
;; Test 6: Central dispatcher calls handler with correct args
;; ============================================================================
(set! *test-handler-calls* '())
(slash-command-hook "/alpha foo bar")
(assert-equal (length *test-handler-calls*) 1
 "Handler called exactly once")
(assert-equal (car (car *test-handler-calls*)) "alpha"
 "Correct handler called")
(assert-equal (cadr (car *test-handler-calls*)) "foo bar"
 "Args passed correctly")

;; Bare command (no args)
(set! *test-handler-calls* '())
(slash-command-hook "/alpha")
(assert-equal (cadr (car *test-handler-calls*)) ""
 "Empty string for bare command")

;; ============================================================================
;; Test 7: Central dispatcher intercepts /<cmd> help
;; ============================================================================
(set! *test-handler-calls* '())
(clear-terminal-output)
(slash-command-hook "/alpha help")
(assert-equal (length *test-handler-calls*) 0
 "Handler NOT called when args is 'help'")
(assert-true (terminal-output-contains? "Alpha command")
 "Help displayed for /alpha help")

;; ============================================================================
;; Test 8: /help lists all commands
;; ============================================================================
(clear-terminal-output)
(slash-help-handler "")
(assert-true (terminal-output-contains? "Slash Commands")
 "/help shows header")
(assert-true (terminal-output-contains? "/alpha")
 "/help lists alpha command")
(assert-true (terminal-output-contains? "/beta")
 "/help lists beta command")
(assert-true (terminal-output-contains? "/help")
 "/help lists itself")

;; ============================================================================
;; Test 9: /help <cmd> shows command help
;; ============================================================================
(clear-terminal-output)
(slash-help-handler "alpha")
(assert-true (terminal-output-contains? "Alpha command")
 "/help alpha shows title")
(assert-true (terminal-output-contains? "An alpha test command")
 "/help alpha shows desc")
;; On-demand help is a report, not a startup banner: each row goes out in
;; its own terminal-echo, terminator included.
(assert-true (> (length *terminal-echo-output*) 0) "/help alpha emits rows")
(do ((msgs *terminal-echo-output* (cdr msgs))) ((null? msgs))
  (let ((msg (car msgs)))
    (assert-equal "\r\n" (substring msg (- (length msg) 2) (length msg))
      "/help alpha row carries its own terminator")))

;; With leading slash
(clear-terminal-output)
(slash-help-handler "/alpha")
(assert-true (terminal-output-contains? "Alpha command")
 "/help /alpha also works")

;; Unknown command
(clear-terminal-output)
(slash-help-handler "nonexistent")
(assert-true (terminal-output-contains? "Unknown command")
 "/help nonexistent shows error")

;; ============================================================================
;; Test 10: /doc works as alias
;; ============================================================================
(assert-equal (slash-command-lookup "/doc") "/help"
 "/doc resolves to /help via alias")

;; ============================================================================
;; Test 11: Non-slash input passes through
;; ============================================================================
(assert-equal (slash-command-hook "hello world") "hello world"
 "Non-slash input passes through")
(assert-equal (slash-command-hook "look north") "look north"
 "Regular MUD command passes through")
(assert-equal (slash-command-hook "") ""
 "Empty string passes through")

;; ============================================================================
;; Test 12: Unregistered command passes through
;; ============================================================================
(assert-equal (slash-command-hook "/zzz") "/zzz"
 "Unregistered /zzz passes through")
(assert-equal (slash-command-hook "/zzz arg") "/zzz arg"
 "Unregistered /zzz with args passes through")

(print "All tests passed!")

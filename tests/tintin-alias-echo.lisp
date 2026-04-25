;; tintin-alias-echo.lisp - Regression test for alias-expansion echoing
;;
;; Bug: when an alias expands to a command that a user-input-hook filter
;; consumes (returns nil), the expanded form was never echoed to the
;; viewport — the user only saw their original input. After the fix,
;; alias-expansion leaves echo through terminal-echo even when consumed.

(load "tests/test-helpers.lisp")
(defmacro load-system-file (name) `(load (string-append "lisp/contrib/" ,name)))
(load "lisp/contrib/tintin.lisp")
(set! *tintin-speedwalk-enabled* #f)

;; Capture terminal-echo calls
(define *echoed* '())
(defun terminal-echo (msg) (set! *echoed* (append *echoed* (list msg))))

(defun echoed-contains? (substr)
  (let ((found nil))
    (do ((rest *echoed* (cdr rest))) ((or found (null? rest)) found)
      (if (string-contains? (car rest) substr) (set! found #t)))))

;; ============================================================================
;; Test 1: Alias whose expansion passes through the filter still echoes
;; ============================================================================
(set! *tintin-alias-depth* 0)
(set! *echoed* '())
(hash-set! *tintin-aliases* "x" (list "where"))

(let ((result (tintin-process-input "x")))
  (assert-equal result "where" "Pass-through alias returns expansion to caller")
  (assert-true (echoed-contains? "where")
    "Pass-through alias echoes its expansion"))

(print "Test 1 passed: pass-through alias echoes expansion")

;; ============================================================================
;; Test 2: Alias whose expansion is consumed by user-input-hook still echoes
;; ============================================================================
(set! *tintin-alias-depth* 0)
(set! *echoed* '())
(hash-set! *tintin-aliases* "a" (list "/foo bar"))

;; Register a consuming filter for /foo (returns nil to consume)
(defun consume-foo (text)
  (if (and (string? text) (string-prefix? "/foo" text)) nil text))
(add-hook 'user-input-hook 'consume-foo 5)

(let ((result (tintin-process-input "a")))
  (assert-equal result "" "Consumed alias produces no server output")
  (assert-true (echoed-contains? "/foo bar")
    "Consumed alias still echoes its expansion"))

(remove-hook 'user-input-hook 'consume-foo)

(print "Test 2 passed: consumed alias still echoes expansion")

;; ============================================================================
;; Test 3: Top-level user input consumed by filter is NOT echoed
;; (depth=0 — user typed it, they already see it on the prompt)
;; ============================================================================
(set! *tintin-alias-depth* 0)
(set! *echoed* '())
(add-hook 'user-input-hook 'consume-foo 5)

(let ((result (tintin-process-input "/foo direct")))
  (assert-equal result "" "Direct /foo consumed, no server output")
  (assert-false (echoed-contains? "/foo direct")
    "Direct (non-alias) consumed input is NOT re-echoed"))

(remove-hook 'user-input-hook 'consume-foo)

(print "Test 3 passed: top-level consumed input is not re-echoed")

;; ============================================================================
;; Test 4: Expansion is echoed BEFORE the consuming handler's own output
;; ============================================================================
(set! *tintin-alias-depth* 0)
(set! *echoed* '())
(hash-set! *tintin-aliases* "b" (list "/baz arg"))

(defun handler-with-output (text)
  (if (and (string? text) (string-prefix? "/baz" text))
    (progn (terminal-echo "[handler] running\r\n") nil)
    text))
(add-hook 'user-input-hook 'handler-with-output 5)

(tintin-process-input "b")

;; Assert that "/baz arg" was echoed strictly before "[handler] running"
(let ((expansion-pos -1)
      (handler-pos -1))
  (do ((i 0 (+ i 1)) (rest *echoed* (cdr rest))) ((null? rest))
    (cond
      ((string-contains? (car rest) "/baz arg") (set! expansion-pos i))
      ((string-contains? (car rest) "[handler] running")
       (set! handler-pos i))))
  (assert-true (>= expansion-pos 0) "Expansion was echoed")
  (assert-true (>= handler-pos 0) "Handler output was echoed")
  (assert-true (< expansion-pos handler-pos)
    "Expansion echo precedes handler output"))

(remove-hook 'user-input-hook 'handler-with-output)

(print "Test 4 passed: expansion echoes before handler output")

(print "")
(print "All alias-echo tests passed!")

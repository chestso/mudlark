;; tests/init-timers.lisp - Timer callbacks survive a Lisp signal
;;
;; ditty 0.9 signals by non-local exit. run-timers detaches *timer-list*
;; while it fires callbacks, so a callback that raises must be caught inside
;; the loop: otherwise the unwind skips the merge at the end and every timer
;; is lost. One failing callback must also not stop the timers after it.

(load "tests/test-helpers.lisp")

;; Deterministic clock: timers fire at exactly the scheduled millisecond.
(defun current-time-ms () 1000)
(defun wake-event-loop () nil)

(load "lisp/init.lisp")

;; Capture diagnostics instead of discarding them.
(define *timer-log* '())
(defun mudlark-log (level category message)
  (set! *timer-log* (append *timer-log* (list (cons category message)))))

;; ============================================================================
;; A raising callback does not stop the callbacks after it
;; ============================================================================
(define timer-fired '())

(run-at-time 0 nil
             (lambda ()
               (set! timer-fired (append timer-fired (list "boom")))
               (car 42)))
(run-at-time 0 nil
             (lambda () (set! timer-fired (append timer-fired (list "good")))))

(run-timers)

(assert-true (not (null? (member "boom" timer-fired)))
             "the raising timer callback ran")
(assert-true (not (null? (member "good" timer-fired)))
             "a raising timer callback does not stop later timers")
(assert-equal (length (filter (lambda (entry) (string=? (car entry) "timers"))
                              *timer-log*))
              1
              "the failed timer callback is logged once")

(print "Timer signal isolation: later timer still fires")

;; ============================================================================
;; A repeater that raises once stays scheduled
;; ============================================================================
(set! timer-fired '())
(set! *timer-list* '())
(set! *timer-log* '())

(define flaky-runs 0)

(run-at-time 0 1
             (lambda ()
               (set! timer-fired (append timer-fired (list "flaky")))
               (set! flaky-runs (+ flaky-runs 1))
               (if (= flaky-runs 1) (car 42) nil)))

(run-timers)

(assert-equal flaky-runs 1 "the flaky repeater ran once")
(assert-true (not (null? *timer-list*))
             "a repeater stays scheduled after its callback signals")

(print "Timer signal isolation: repeater survives a signal")

(print "")
(print "All timer signal tests passed!")

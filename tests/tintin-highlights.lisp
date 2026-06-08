;; tests/tintin-highlights.lisp - Tests for highlight pipeline
(load "tests/test-loader.lisp")

;; ============================================================================
;; tintin-parse-ansi - plain text extraction
;; ============================================================================
(let ((result (tintin-parse-ansi "hello world")))
  (assert-equal (car result) "hello world" "parse-ansi plain text unchanged")
  (assert-equal (cdr result) '() "parse-ansi no codes in plain text"))

;; ============================================================================
;; tintin-parse-ansi - strips ANSI, builds ansi-map
;; ============================================================================
(let ((result (tintin-parse-ansi "\033[31mhello\033[0m")))
  (assert-equal (car result) "hello" "parse-ansi extracts plain text from ANSI")
  (assert-equal (length (cdr result)) 2 "parse-ansi two entries in ansi-map")
  ;; First entry: color code at position 0
  (assert-equal (car (car (cdr result))) 0
   "parse-ansi first code at position 0")
  (assert-equal (cdr (car (cdr result))) "\033[31m"
   "parse-ansi first code is red")
  ;; Second entry: reset at position 5 (after "hello")
  (assert-equal (car (cadr (cdr result))) 5
   "parse-ansi reset at position 5")
  (assert-equal (cdr (cadr (cdr result))) "\033[0m"
   "parse-ansi second code is reset"))

;; ============================================================================
;; tintin-parse-ansi - edge cases (forward port-walk parity)
;; ============================================================================
;; Lone ESC not followed by '[' stays as plain text
(let ((result (tintin-parse-ansi "a\033b")))
  (assert-equal (car result) "a\033b" "parse-ansi lone ESC is plain")
  (assert-equal (cdr result) '() "parse-ansi lone ESC adds no code"))

;; ESC as the final character stays plain
(let ((result (tintin-parse-ansi "ab\033")))
  (assert-equal (car result) "ab\033" "parse-ansi trailing ESC is plain")
  (assert-equal (cdr result) '() "parse-ansi trailing ESC adds no code"))

;; Malformed CSI with no terminator (EOF mid-params) falls back to plain text
(let ((result (tintin-parse-ansi "x\033[12")))
  (assert-equal (car result) "x\033[12" "parse-ansi malformed CSI is plain")
  (assert-equal (cdr result) '() "parse-ansi malformed CSI adds no code"))

;; CSI broken by a non-parameter, non-letter byte also falls back to plain
(let ((result (tintin-parse-ansi "x\033[1 m")))
  (assert-equal (car result) "x\033[1 m" "parse-ansi CSI broken by space is plain")
  (assert-equal (cdr result) '() "parse-ansi broken CSI adds no code"))

;; Two consecutive codes share the same plain-text position
(let ((result (tintin-parse-ansi "\033[1m\033[31mhi")))
  (assert-equal (car result) "hi" "parse-ansi consecutive codes strip to plain")
  (assert-equal (length (cdr result)) 2 "parse-ansi two consecutive codes")
  (assert-equal (car (car (cdr result))) 0 "parse-ansi first consec code at 0")
  (assert-equal (car (cadr (cdr result))) 0 "parse-ansi second consec code at 0"))

;; A valid code followed immediately by a malformed one: the malformed bytes
;; become plain text right after the valid code's position.
(let ((result (tintin-parse-ansi "\033[31mhi\033[9")))
  (assert-equal (car result) "hi\033[9" "parse-ansi valid then malformed")
  (assert-equal (length (cdr result)) 1 "parse-ansi only the valid code recorded"))

;; ============================================================================
;; tintin-find-all-regex-positions
;; ============================================================================
(let ((positions (tintin-find-all-regex-positions "hello world hello" "hello")))
  (assert-equal (length positions) 2
   "find-all-regex-positions finds two matches")
  (assert-equal (car (car positions)) 0
   "find-all-regex-positions first match at 0")
  (assert-equal (cdr (car positions)) 5
   "find-all-regex-positions first match ends at 5")
  (assert-equal (car (cadr positions)) 12
   "find-all-regex-positions second match at 12")
  (assert-equal (cdr (cadr positions)) 17
   "find-all-regex-positions second match ends at 17"))

(let ((positions (tintin-find-all-regex-positions "no match here" "xyz")))
  (assert-equal positions '() "find-all-regex-positions no match returns empty"))

;; ============================================================================
;; tintin-highlight-line - end-to-end with registered highlights
;; ============================================================================
;; Register a highlight: pattern -> (fg bg priority)
(hash-set! *tintin-highlights* "orc" '("red" nil 5))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line "an orc appears")))
  ;; Should contain ANSI red around "orc"
  (assert-true (string-contains? result "\033[31m")
   "highlight-line contains red ANSI code")
  (assert-true (string-contains? result "orc")
   "highlight-line still contains the word orc"))

;; Clean up
(hash-remove! *tintin-highlights* "orc")
(set! *tintin-highlights-dirty* #t)

;; ============================================================================
;; tintin-highlight-line - no highlights returns original
;; ============================================================================
(let ((line "nothing to highlight"))
  (assert-equal (tintin-highlight-line line) line
   "highlight-line no highlights returns original"))

;; ============================================================================
;; tintin-apply-highlights - multi-line processing
;; ============================================================================
(hash-set! *tintin-highlights* "goblin" '("green" nil 5))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-apply-highlights "a goblin\na goblin\n")))
  ;; Should have green ANSI on both lines
  (assert-true (string-contains? result "\033[32m")
   "apply-highlights contains green ANSI"))

;; Clean up
(hash-remove! *tintin-highlights* "goblin")
(set! *tintin-highlights-dirty* #t)

;; ============================================================================
;; Overlapping highlights: "is" inside "this is a line"
;; ============================================================================
(hash-set! *tintin-highlights* "is" '("red" nil 5))
(hash-set! *tintin-highlights* "this is" '("blue" nil 10))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line "this is a line")))
  ;; Higher-priority "this is" (blue=34) should win over "is" (red=31)
  (assert-true (string-contains? result "\033[34m")
   "overlapping highlights higher priority wins"))

;; Clean up
(hash-remove! *tintin-highlights* "is")
(hash-remove! *tintin-highlights* "this is")
(set! *tintin-highlights-dirty* #t)

;; ============================================================================
;; Server ANSI preservation
;; ============================================================================
(hash-set! *tintin-highlights* "world" '("green" nil 5))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line "\033[31mhello\033[0m world")))
  ;; Should still contain the green highlight for "world"
  (assert-true (string-contains? result "\033[32m")
   "server-ansi preservation green highlight applied")
  ;; Should contain the original server codes
  (assert-true (string-contains? result "\033[31m")
   "server-ansi preservation original red preserved"))

;; Clean up
(hash-remove! *tintin-highlights* "world")
(set! *tintin-highlights-dirty* #t)

;; ============================================================================
;; Server ANSI punches through highlights
;; ============================================================================

;; A. Server color punches through wildcard highlight
(hash-set! *tintin-highlights* "^%* vicious attack %*" '("green" nil 5))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line
               "Paersos's vicious attack \033[31mmaims\033[0m Whulian!")))
  ;; Server red should punch through the green highlight
  (assert-true (string-contains? result "\033[31m")
   "server-punch-through server red preserved inside highlight")
  ;; Green highlight should resume after server reset
  (assert-true (string-contains? result "\033[32m")
   "server-punch-through green highlight resumes after reset"))

;; B. Whole-line server color punches through highlight
(let ((result (tintin-highlight-line
               "\033[36mSomeone's vicious attack hurts you!\033[0m")))
  ;; Server cyan should appear in output
  (assert-true (string-contains? result "\033[36m")
   "server-punch-through whole-line server cyan preserved"))

;; C. Server bold+red punches through
(hash-set! *tintin-highlights* "^%* pierce %*" '("yellow" nil 5))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line
               "An ugruk hunter's pierce \033[31;1mdecimates\033[0m you!")))
  (assert-true (string-contains? result "\033[31;1m")
   "server-punch-through bold+red preserved inside highlight"))

(hash-remove! *tintin-highlights* "^%* pierce %*")
(set! *tintin-highlights-dirty* #t)

;; D. Multiple server colors in one highlighted line
(hash-set! *tintin-highlights* "^%* searing cut %*" '("cyan" nil 5))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line
               "A troll's searing cut \033[31mmaims\033[0m and \033[33mburns\033[0m you!")))
  (assert-true (string-contains? result "\033[31m")
   "server-punch-through first server color preserved")
  (assert-true (string-contains? result "\033[33m")
   "server-punch-through second server color preserved"))

(hash-remove! *tintin-highlights* "^%* searing cut %*")
(set! *tintin-highlights-dirty* #t)

;; E. Skill improvement line (server bold yellow, highlight red)
(hash-set! *tintin-highlights* "You have become better" '("red" nil 5))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line
               "\033[33;1mYou have become better at truesight (82%)!\033[0m")))
  ;; The highlight should apply red to the matched portion
  (assert-true (string-contains? result "\033[31m")
   "server-punch-through skill line highlight red applied")
  ;; Server bold yellow should also appear (punches through)
  (assert-true (string-contains? result "\033[33;1m")
   "server-punch-through skill line server bold yellow preserved"))

(hash-remove! *tintin-highlights* "You have become better")
(set! *tintin-highlights-dirty* #t)

;; F. No server ANSI - highlight unchanged (regression check)
(let ((result (tintin-highlight-line
               "Paersos's vicious attack maims Whulian!")))
  ;; Only green highlight code should be present
  (assert-true (string-contains? result "\033[32m")
   "no-server-ansi green highlight applied")
  ;; No server red should appear since input has none
  (assert-false (string-contains? result "\033[31m")
   "no-server-ansi no unexpected red code"))

;; G. Server color without reset inside highlight
(let ((result (tintin-highlight-line
               "Paersos's vicious attack \033[31mmaims Whulian!")))
  ;; Server red should still appear
  (assert-true (string-contains? result "\033[31m")
   "server-no-reset server color preserved without reset"))

;; H. Non-wildcard pattern still works (regression)
(hash-remove! *tintin-highlights* "^%* vicious attack %*")
(hash-set! *tintin-highlights* "orc" '("red" nil 5))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line "an orc appears")))
  (assert-true (string-contains? result "\033[31m")
   "non-wildcard highlight red applied to orc"))

;; Clean up
(hash-remove! *tintin-highlights* "orc")
(set! *tintin-highlights-dirty* #t)

;; ============================================================================
;; Nested user highlights on top of server ANSI
;; ============================================================================

;; I. Two user highlights, higher-priority one overlaps server color region
;;    "maims" is server red, "vicious attack" is green (pri 5),
;;    "maims" also has a higher-priority yellow highlight (pri 10)
(hash-set! *tintin-highlights* "^%* vicious attack %*" '("green" nil 5))
(hash-set! *tintin-highlights* "maims" '("yellow" nil 10))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line
               "Paersos's vicious attack \033[31mmaims\033[0m Whulian!")))
  ;; Yellow highlight (pri 10) should win over green for "maims"
  (assert-true (string-contains? result "\033[33m")
   "nested-highlights yellow highlight wins for maims")
  ;; Green highlight should be present for the rest of the match
  (assert-true (string-contains? result "\033[32m")
   "nested-highlights green highlight on surrounding text")
  ;; Server red should punch through (emitted before highlight transition)
  (assert-true (string-contains? result "\033[31m")
   "nested-highlights server red still emitted"))

(hash-remove! *tintin-highlights* "^%* vicious attack %*")
(hash-remove! *tintin-highlights* "maims")
(set! *tintin-highlights-dirty* #t)

;; J. Lower-priority highlight does not override higher inside server color
;;    "attack maims" is blue (pri 3), whole line is green (pri 5)
(hash-set! *tintin-highlights* "^%* vicious attack %*" '("green" nil 5))
(hash-set! *tintin-highlights* "attack maims" '("blue" nil 3))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line
               "Paersos's vicious attack \033[31mmaims\033[0m Whulian!")))
  ;; Green (pri 5) should win over blue (pri 3) in the overlap
  (assert-true (string-contains? result "\033[32m")
   "nested-lower-pri green wins over blue")
  ;; Server red still punches through
  (assert-true (string-contains? result "\033[31m")
   "nested-lower-pri server red preserved"))

(hash-remove! *tintin-highlights* "^%* vicious attack %*")
(hash-remove! *tintin-highlights* "attack maims")
(set! *tintin-highlights-dirty* #t)

;; K. Adjacent user highlights with server color at the boundary
;;    "attack" is green (pri 5), "maims" is red highlight (pri 5)
;;    Server sends bold on "maims"
(hash-set! *tintin-highlights* "attack" '("green" nil 5))
(hash-set! *tintin-highlights* "maims" '("red" nil 5))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line
               "Your attack \033[1mmaims\033[0m the orc")))
  ;; Green highlight on "attack"
  (assert-true (string-contains? result "\033[32m")
   "adjacent-highlights green on attack")
  ;; Red highlight on "maims"
  (assert-true (string-contains? result "\033[31m")
   "adjacent-highlights red on maims")
  ;; Server bold should punch through
  (assert-true (string-contains? result "\033[1m")
   "adjacent-highlights server bold preserved"))

(hash-remove! *tintin-highlights* "attack")
(hash-remove! *tintin-highlights* "maims")
(set! *tintin-highlights-dirty* #t)

;; L. High-priority highlight fully inside server-colored region
;;    Server sends entire line cyan, user highlights "decimates" red (pri 10)
(hash-set! *tintin-highlights* "decimates" '("red" nil 10))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line
               "\033[36mThe troll's attack decimates you!\033[0m")))
  ;; Red highlight should apply to "decimates"
  (assert-true (string-contains? result "\033[31m")
   "highlight-inside-server-color red highlight applied")
  ;; Server cyan should appear for text outside the highlight
  (assert-true (string-contains? result "\033[36m")
   "highlight-inside-server-color server cyan preserved"))

(hash-remove! *tintin-highlights* "decimates")
(set! *tintin-highlights-dirty* #t)

;; M. Three-layer: server color + low-pri highlight + high-pri highlight
;;    Server sends bold, whole line has green (pri 3), "critical" has red (pri 8)
(hash-set! *tintin-highlights* "^%*critical%*" '("green" nil 3))
(hash-set! *tintin-highlights* "critical" '("red" nil 8))
(set! *tintin-highlights-dirty* #t)

(let ((result (tintin-highlight-line
               "\033[1mYou land a critical hit!\033[0m")))
  ;; Red (pri 8) should win on "critical"
  (assert-true (string-contains? result "\033[31m")
   "three-layer red highlight on critical")
  ;; Green (pri 3) should appear on surrounding text
  (assert-true (string-contains? result "\033[32m")
   "three-layer green highlight on surrounding")
  ;; Server bold should punch through both
  (assert-true (string-contains? result "\033[1m")
   "three-layer server bold preserved"))

(hash-remove! *tintin-highlights* "^%*critical%*")
(hash-remove! *tintin-highlights* "critical")
(set! *tintin-highlights-dirty* #t)

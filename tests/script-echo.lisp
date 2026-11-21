;; tests/script-echo.lisp - Tests for script-echo styled banners
;; This test loads the actual init.lisp to test the real implementation.
;; Expected colors are the Dracula palette defined in init.lisp.
(load "tests/test-helpers.lisp")

;; ============================================================================
;; Override mocks with capturing/marker versions for this test
;; ============================================================================
(defvar *terminal-output* '() "Captured terminal-echo calls")

(defun terminal-echo (msg)
  "Mock: capture output instead of displaying"
  (set! *terminal-output* (append *terminal-output* (list msg))))

(defun termcap (capability &rest args)
  "Mock: return bracketed markers instead of escape codes for easy testing"
  (cond
   ((eq? capability 'fg-color)
    (format nil "[fg:~A,~A,~A]" (car args) (cadr args) (caddr args)))
   ((eq? capability 'reset) "[reset]")
   ((eq? capability 'truecolor?) #t)
   ((eq? capability 'width-model) "grid")
   (#t "")))

;; ============================================================================
;; Load actual init.lisp to test the real script-echo implementation
;; ============================================================================
(load "lisp/init.lisp")

;; ============================================================================
;; Test helpers
;; ============================================================================
(defun reset-output ()
  (set! *terminal-output* '()))

(defun get-output ()
  "Return all captured output as a single string"
  (apply concat *terminal-output*))

(defun contains? (haystack needle)
  "Check if haystack contains needle substring"
  (not (null? (string-index haystack needle))))

;; ============================================================================
;; Test: Simple title only
;; ============================================================================
(reset-output)
(script-echo "My Script")
(assert-true (contains? (get-output) "[fg:255,121,198]My Script[reset]")
  "Simple title shows header color")
(assert-true (contains? (get-output) "\r\n")
  "Output ends with newline")

;; ============================================================================
;; Test: Title with description
;; ============================================================================
(reset-output)
(script-echo "My Script" :desc "a short description")
(let ((out (get-output)))
  (assert-true (contains? out "[fg:255,121,198]My Script[reset]")
    "Title with desc shows header")
  (assert-true (contains? out "[fg:98,114,164] — [reset]")
    "Mdash has comment color")
  (assert-true (contains? out "[fg:139,233,253]a short description[reset]")
    "Description has cyan color"))

;; ============================================================================
;; Test: Title with single section (multiline string)
;; ============================================================================
(reset-output)
(script-echo "My Script"
  :section "Usage\ncommand1\ncommand2")
(let ((out (get-output)))
  (assert-true (contains? out "[fg:189,147,249]Usage[reset]")
    "Section title has purple color")
  (assert-true (contains? out "[fg:98,114,164]command1[reset]")
    "Detail 1 has comment color")
  (assert-true (contains? out "[fg:98,114,164]command2[reset]")
    "Detail 2 has comment color"))

;; ============================================================================
;; Test: Multiple sections
;; ============================================================================
(reset-output)
(script-echo "My Script"
  :desc "description"
  :section "Usage\ncmd1"
  :section "Features\nfeat1\nfeat2"
  :section "Config\ncfg1")
(let ((out (get-output)))
  (assert-true (contains? out "Usage") "Has Usage section")
  (assert-true (contains? out "Features") "Has Features section")
  (assert-true (contains? out "Config") "Has Config section")
  (assert-true (contains? out "cmd1") "Has cmd1 detail")
  (assert-true (contains? out "feat1") "Has feat1 detail")
  (assert-true (contains? out "feat2") "Has feat2 detail")
  (assert-true (contains? out "cfg1") "Has cfg1 detail"))

;; ============================================================================
;; Test: Simple title (no sections)
;; ============================================================================
(reset-output)
(script-echo "TinTin++ active")
(let ((out (get-output)))
  (assert-true (contains? out "[fg:255,121,198]TinTin++ active[reset]")
    "Simple title renders"))

;; ============================================================================
;; Test: Single-line section renders as detail
;; ============================================================================
(reset-output)
(script-echo "App" :section "Single item section")
(let ((out (get-output)))
  (assert-true (contains? out "[fg:98,114,164]Single item section[reset]")
    "Single-line section renders as detail"))

;; ============================================================================
;; Test: Empty args (just title)
;; ============================================================================
(reset-output)
(script-echo "Just Title")
(let ((out (get-output)))
  (assert-equal (length *terminal-output*) 1
    "Just title produces one output (row + terminator)")
  (assert-true (contains? out "Just Title")
    "Just title shows title"))

;; ============================================================================
;; Test: every row carries its own terminator
;; ============================================================================
;; A row must not lean on the next write to close it: script-echo (through
;; echo-styled-page) appends the "\r\n" to the row it terminates, in the
;; same terminal-echo call.
(reset-output)
(script-echo "App" :desc "a description" :section "Usage\ncmd1\ncmd2")
(do ((msgs *terminal-output* (cdr msgs))) ((null? msgs))
  (let ((msg (car msgs)))
    (assert-true (>= (length msg) 2) "row has room for a terminator")
    (assert-equal "\r\n" (substring msg (- (length msg) 2) (length msg))
      "row carries its own terminator")))

;; ============================================================================
;; Test: Indentation levels
;; ============================================================================
(reset-output)
(script-echo "App"
  :section "Section\ndetail")
(let ((out (get-output)))
  (assert-true (contains? out "  [fg:189,147,249]Section")
    "Section has 2-space indent")
  (assert-true (contains? out "    [fg:98,114,164]detail")
    "Detail has 4-space indent"))

;; ============================================================================
;; Test: Description and sections together
;; ============================================================================
(reset-output)
(script-echo "mudlark 1.0"
  :desc ":help for commands"
  :section "Terminal\nxterm-256color")
(let ((out (get-output)))
  (assert-true (contains? out "mudlark 1.0")
    "Has title")
  (assert-true (contains? out ":help for commands")
    "Has description")
  (assert-true (contains? out "Terminal")
    "Has section title")
  (assert-true (contains? out "xterm-256color")
    "Has section detail"))

;; ============================================================================
;; Test: CRLF section text does not leave blank rows
;; ============================================================================
;; A section string from a CRLF source file (a Windows checkout, a
;; hand-edited script) splits on "\n" with a trailing CR left on every
;; line. script-echo must drop it before appending its own "\r\n", or the
;; transcript reads the stray CR plus the terminator as two row breaks and
;; every announced line grows a blank row beneath it.
(reset-output)
(script-echo "App"
  :section "Usage\r\ncmd1\r\ncmd2")
(let ((out (get-output)))
  (assert-false (contains? out "\r\r")
    "CRLF section emits no doubled row breaks")
  (assert-true (contains? out "[fg:189,147,249]Usage[reset]\r\n")
    "Section title keeps a single row break")
  (assert-true (contains? out "[fg:98,114,164]cmd1[reset]\r\n")
    "Detail line keeps a single row break"))

;; ============================================================================
;; Test: color->fg passes the optional ANSI16 slot through to termcap
;; ============================================================================
;; The slot is the fourth element of an (R G B SLOT) color list: it rides
;; along to termcap as a fourth argument, which picks the fallback spelling
;; for a terminal without truecolor. Redefine the mock (this is the last
;; test, so nothing below depends on the old one) to record its arguments.
(defvar *tc-args* '())
(defun termcap (capability &rest args)
  (set! *tc-args* args)
  (cond
    ((eq? capability 'fg-color) "")
    ((eq? capability 'reset) "")
    ((eq? capability 'truecolor?) #t)
    ((eq? capability 'width-model) "grid")
    (#t "")))

(color->fg '(139 233 253 14))
(assert-equal 4 (length *tc-args*) "color->fg passes the slot as a fourth argument")
(assert-equal 14 (car (cdr (cdr (cdr *tc-args*)))) "the slot value reaches termcap")

(color->fg '(139 233 253))
(assert-equal 3 (length *tc-args*) "a plain RGB list passes three arguments")

(print "All script-echo tests passed!")
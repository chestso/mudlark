;;; tintin-mode-tests.el --- Tests for tintin-mode  -*- lexical-binding: t; -*-

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;;; Commentary:

;; ERT test suite for tintin-mode.

;;; Code:

(require 'ert)
(require 'tintin-mode)

;; ============================================================================
;; Helpers
;; ============================================================================

(defun tintin-test-face-at (text pos)
  "Insert TEXT into a temp buffer in `tintin-mode', return face at POS."
  (with-temp-buffer
    (tintin-mode)
    (insert text)
    (font-lock-ensure)
    (get-text-property pos 'face)))

(defun tintin-test-indent (text)
  "Insert TEXT, run `indent-region', return the indented result."
  (with-temp-buffer
    (tintin-mode)
    (insert text)
    (indent-region (point-min) (point-max))
    (buffer-string)))

;; ============================================================================
;; Mode activation
;; ============================================================================

(ert-deftest tintin-test-mode-name ()
  "Mode name should be TinTin++."
  (with-temp-buffer
    (tintin-mode)
    (should (equal mode-name "TinTin++"))))

(ert-deftest tintin-test-derived-from-prog-mode ()
  "Should derive from prog-mode."
  (with-temp-buffer
    (tintin-mode)
    (should (derived-mode-p 'prog-mode))))

(ert-deftest tintin-test-auto-mode-alist ()
  "The .tin extension should be in auto-mode-alist."
  (should (assoc "\\.tin\\'" auto-mode-alist)))

;; ============================================================================
;; Font-lock: commands
;; ============================================================================

(ert-deftest tintin-test-face-action ()
  "#action should get tintin-command-face."
  (should (eq (tintin-test-face-at "#action {pattern} {cmd}" 1)
              'tintin-command-face)))

(ert-deftest tintin-test-face-alias ()
  "#alias should get tintin-command-face."
  (should (eq (tintin-test-face-at "#alias {k} {kill}" 1)
              'tintin-command-face)))

(ert-deftest tintin-test-face-case-insensitive ()
  "#ACTION should highlight the same as #action."
  (should (eq (tintin-test-face-at "#ACTION {pattern} {cmd}" 1)
              'tintin-command-face)))

(ert-deftest tintin-test-face-catch-all ()
  "Unknown #command should get tintin-command-face."
  (should (eq (tintin-test-face-at "#foobar something" 1)
              'tintin-command-face)))

;; ============================================================================
;; Font-lock: control flow
;; ============================================================================

(ert-deftest tintin-test-face-if ()
  "#if should get tintin-control-face."
  (should (eq (tintin-test-face-at "#if {$hp < 50} {drink potion}" 1)
              'tintin-control-face)))

(ert-deftest tintin-test-face-else ()
  "#else should get tintin-control-face."
  (should (eq (tintin-test-face-at "#else {run}" 1)
              'tintin-control-face)))

(ert-deftest tintin-test-face-while ()
  "#while should get tintin-control-face."
  (should (eq (tintin-test-face-at "#while {$i < 10} {#math i {$i + 1}}" 1)
              'tintin-control-face)))

(ert-deftest tintin-test-face-loop ()
  "#loop should get tintin-control-face."
  (should (eq (tintin-test-face-at "#loop {1} {5} {i} {get $i}" 1)
              'tintin-control-face)))

(ert-deftest tintin-test-face-foreach ()
  "#foreach should get tintin-control-face."
  (should (eq (tintin-test-face-at "#foreach {a;b;c} {x} {say $x}" 1)
              'tintin-control-face)))

;; ============================================================================
;; Font-lock: functions/classes
;; ============================================================================

(ert-deftest tintin-test-face-function ()
  "#function should get tintin-function-face."
  (should (eq (tintin-test-face-at "#function {greet} {#return hello}" 1)
              'tintin-function-face)))

(ert-deftest tintin-test-face-class ()
  "#class should get tintin-function-face."
  (should (eq (tintin-test-face-at "#class {combat} {open}" 1)
              'tintin-function-face)))

(ert-deftest tintin-test-face-function-call ()
  "@funcname should get tintin-function-face."
  (let ((face (tintin-test-face-at "say @greet{world}" 6)))
    (should (eq face 'tintin-function-face))))

;; ============================================================================
;; Font-lock: variables
;; ============================================================================

(ert-deftest tintin-test-face-dollar-variable ()
  "$variable should get tintin-variable-face."
  (should (eq (tintin-test-face-at "say $name" 5)
              'tintin-variable-face)))

(ert-deftest tintin-test-face-ampersand-variable ()
  "&variable should get tintin-variable-face."
  (should (eq (tintin-test-face-at "say &targets" 5)
              'tintin-variable-face)))

(ert-deftest tintin-test-face-star-variable ()
  "*variable should get tintin-variable-face."
  (should (eq (tintin-test-face-at "say *items" 5)
              'tintin-variable-face)))

(ert-deftest tintin-test-face-capture-arg ()
  "%1 should get tintin-variable-face."
  (should (eq (tintin-test-face-at "tell %1 hello" 6)
              'tintin-variable-face)))

(ert-deftest tintin-test-face-capture-two-digit ()
  "%99 should get tintin-variable-face."
  (should (eq (tintin-test-face-at "tell %99 hello" 6)
              'tintin-variable-face)))

(ert-deftest tintin-test-face-capture-wildcard ()
  "%* should get tintin-variable-face."
  (should (eq (tintin-test-face-at "#action {%*} {say hi}" 10)
              'tintin-variable-face)))

;; ============================================================================
;; Font-lock: numbers and speedwalks
;; ============================================================================

(ert-deftest tintin-test-face-number ()
  "Numeric literal should get tintin-number-face."
  (should (eq (tintin-test-face-at "#loop {1} {5} {i} {get}" 8)
              'tintin-number-face)))

(ert-deftest tintin-test-face-float ()
  "Float literal should get tintin-number-face."
  (should (eq (tintin-test-face-at "#math x {3.14}" 10)
              'tintin-number-face)))

;; Positive: speedwalks/directions inside braces as standalone commands

(ert-deftest tintin-test-face-speedwalk-in-braces ()
  "Speedwalk inside braces should get tintin-number-face."
  (should (eq (tintin-test-face-at "{3n2e}" 2)
              'tintin-number-face)))

(ert-deftest tintin-test-face-speedwalk-diagonal ()
  "Diagonal speedwalk inside braces should get tintin-number-face."
  (should (eq (tintin-test-face-at "{2sw3ne}" 2)
              'tintin-number-face)))

(ert-deftest tintin-test-face-direction-in-braces ()
  "Bare direction inside braces should get tintin-number-face."
  (should (eq (tintin-test-face-at "{w;look}" 2)
              'tintin-number-face)))

(ert-deftest tintin-test-face-direction-with-count ()
  "Direction with count inside braces should get tintin-number-face."
  (should (eq (tintin-test-face-at "{3e;look}" 2)
              'tintin-number-face)))

(ert-deftest tintin-test-face-direction-after-semicolon ()
  "Direction after semicolon should get tintin-number-face."
  (should (eq (tintin-test-face-at "{look;e}" 7)
              'tintin-number-face)))

(ert-deftest tintin-test-face-speedwalk-after-semicolon ()
  "Speedwalk after semicolon should get tintin-number-face."
  (should (eq (tintin-test-face-at "{look;3n2e}" 7)
              'tintin-number-face)))

(ert-deftest tintin-test-face-direction-between-semicolons ()
  "Direction between semicolons should get tintin-number-face."
  (should (eq (tintin-test-face-at "{look;s;say hi}" 7)
              'tintin-number-face)))

;; Negative: should NOT highlight outside braces or mid-command

(ert-deftest tintin-test-face-speedwalk-outside-braces ()
  "Speedwalk outside braces should NOT get tintin-number-face."
  (should-not (eq (tintin-test-face-at "3n2e" 1)
                  'tintin-number-face)))

(ert-deftest tintin-test-face-direction-outside-braces ()
  "Bare direction outside braces should NOT get tintin-number-face."
  (should-not (eq (tintin-test-face-at "w" 1)
                  'tintin-number-face)))

(ert-deftest tintin-test-face-non-direction-in-braces ()
  "Non-direction word in braces should NOT get tintin-number-face."
  (should-not (eq (tintin-test-face-at "{g all box}" 2)
                  'tintin-number-face)))

(ert-deftest tintin-test-face-word-is-speedwalk ()
  "Word composed entirely of direction letters is a speedwalk."
  (should (eq (tintin-test-face-at "{news}" 2)
              'tintin-number-face)))

(ert-deftest tintin-test-face-direction-mid-command ()
  "Direction letter mid-command should NOT get tintin-number-face."
  (should-not (eq (tintin-test-face-at "{get east}" 6)
                  'tintin-number-face)))

;; Context-aware: suppress speedwalk in first brace of name/pattern commands

(ert-deftest tintin-test-face-speedwalk-suppressed-action ()
  "Speedwalk-like word in #action's first brace should NOT highlight."
  (should-not (eq (tintin-test-face-at "#action {news} {read}" 10)
                  'tintin-number-face)))

(ert-deftest tintin-test-face-speedwalk-suppressed-alias ()
  "Direction in #alias's first brace should NOT highlight."
  (should-not (eq (tintin-test-face-at "#alias {sw} {go southwest}" 9)
                  'tintin-number-face)))

(ert-deftest tintin-test-face-speedwalk-suppressed-highlight ()
  "Speedwalk-like word in #highlight's first brace should NOT highlight."
  (should-not (eq (tintin-test-face-at "#highlight {news} {bold}" 13)
                  'tintin-number-face)))

(ert-deftest tintin-test-face-speedwalk-suppressed-function ()
  "Direction-letter name in #function's first brace should NOT highlight."
  (should-not (eq (tintin-test-face-at "#function {send} {code}" 12)
                  'tintin-number-face)))

(ert-deftest tintin-test-face-speedwalk-preserved-second-brace ()
  "Speedwalk in second brace of #action should still highlight."
  (should (eq (tintin-test-face-at "#action {pat} {3n2e}" 16)
              'tintin-number-face)))

(ert-deftest tintin-test-face-speedwalk-preserved-alias-body ()
  "Direction in #alias body should still highlight."
  (should (eq (tintin-test-face-at "#alias {name} {sw;look}" 16)
              'tintin-number-face)))

(ert-deftest tintin-test-face-speedwalk-first-suppressed-second-preserved ()
  "Same word: suppressed in first brace, highlighted in second."
  (should-not (eq (tintin-test-face-at "#action {news} {news}" 10)
                  'tintin-number-face))
  (should (eq (tintin-test-face-at "#action {news} {news}" 17)
              'tintin-number-face)))

(ert-deftest tintin-test-face-speedwalk-bare-braces-preserved ()
  "Speedwalk in bare braces (no command) should still highlight."
  (should (eq (tintin-test-face-at "{3n2e}" 2)
              'tintin-number-face)))

(ert-deftest tintin-test-face-speedwalk-suppressed-case-insensitive ()
  "Suppression should work with uppercase commands."
  (should-not (eq (tintin-test-face-at "#ACTION {news} {code}" 10)
                  'tintin-number-face)))

(ert-deftest tintin-test-face-speedwalk-suppressed-multiline ()
  "Suppression should work across lines."
  (should-not (eq (tintin-test-face-at "#action\n  {news}\n  {code}" 12)
                  'tintin-number-face)))

(ert-deftest tintin-test-face-speedwalk-nested-preserved ()
  "Speedwalk in nested command body should still highlight."
  (should (eq (tintin-test-face-at "#alias {name} {#if {1} {sw}}" 26)
              'tintin-number-face)))

(ert-deftest tintin-test-face-number-suppressed-in-name-arg ()
  "Number in first brace of #action should NOT get number face."
  (should-not (eq (tintin-test-face-at "#action {100} {code}" 10)
                  'tintin-number-face)))

(ert-deftest tintin-test-face-number-preserved-in-code-arg ()
  "Number in second brace of #action should still get number face."
  (should (eq (tintin-test-face-at "#action {pat} {100}" 16)
              'tintin-number-face)))

(ert-deftest tintin-test-face-number-preserved-in-control-flow ()
  "Number in #if condition should still get number face."
  (should (eq (tintin-test-face-at "#if {1} {code}" 6)
              'tintin-number-face)))

;; ============================================================================
;; Font-lock: special syntax
;; ============================================================================

(ert-deftest tintin-test-face-escape-sequence ()
  "Escape sequence \\n should get tintin-special-face."
  (let ((face (tintin-test-face-at "say \\n" 5)))
    (should (or (eq face 'tintin-special-face)
                (and (listp face) (memq 'tintin-special-face face))))))

(ert-deftest tintin-test-face-semicolon ()
  "Semicolon should get tintin-special-face."
  (should (eq (tintin-test-face-at "north;south" 6)
              'tintin-special-face)))

(ert-deftest tintin-test-face-open-brace ()
  "Open brace should get tintin-special-face."
  (should (eq (tintin-test-face-at "#if {true}" 5)
              'tintin-special-face)))

(ert-deftest tintin-test-face-close-brace ()
  "Close brace should get tintin-special-face."
  (should (eq (tintin-test-face-at "#if {true}" 10)
              'tintin-special-face)))

;; ============================================================================
;; Font-lock: commands (additional categories)
;; ============================================================================

(ert-deftest tintin-test-face-variable-command ()
  "#variable should get tintin-command-face."
  (should (eq (tintin-test-face-at "#variable {hp} {100}" 1)
              'tintin-command-face)))

(ert-deftest tintin-test-face-other-command ()
  "#send should get tintin-command-face."
  (should (eq (tintin-test-face-at "#send {hello}" 1)
              'tintin-command-face)))

(ert-deftest tintin-test-face-event ()
  "#event should get tintin-function-face."
  (should (eq (tintin-test-face-at "#event {SESSION CONNECTED}" 1)
              'tintin-function-face)))

;; ============================================================================
;; Font-lock: comments
;; ============================================================================

(ert-deftest tintin-test-face-nop-comment ()
  "#nop should get tintin-comment-face."
  (should (eq (tintin-test-face-at "#nop this is a comment" 1)
              'tintin-comment-face)))

(ert-deftest tintin-test-face-nop-comment-body ()
  "Text after #nop should also get tintin-comment-face."
  (should (eq (tintin-test-face-at "#nop this is a comment" 10)
              'tintin-comment-face)))

;; ============================================================================
;; Syntax table: comments
;; ============================================================================

(ert-deftest tintin-test-block-comment ()
  "/* ... */ should be recognized as a comment."
  (with-temp-buffer
    (tintin-mode)
    (insert "/* block comment */")
    (font-lock-ensure)
    (let ((ppss (syntax-ppss 10)))
      (should (nth 4 ppss)))))

(ert-deftest tintin-test-line-comment ()
  "// should be recognized as a line comment."
  (with-temp-buffer
    (tintin-mode)
    (insert "// line comment")
    (font-lock-ensure)
    (let ((ppss (syntax-ppss 5)))
      (should (nth 4 ppss)))))

;; ============================================================================
;; Brace matching
;; ============================================================================

(ert-deftest tintin-test-brace-syntax-class ()
  "{ and } should be paired delimiters."
  (with-temp-buffer
    (tintin-mode)
    (should (eq (char-syntax ?{) ?\())
    (should (eq (char-syntax ?}) ?\)))))

;; ============================================================================
;; Indentation
;; ============================================================================

(ert-deftest tintin-test-indent-top-level ()
  "Top-level line should have zero indentation."
  (let ((result (tintin-test-indent "#alias {k} {kill}")))
    (should (equal result "#alias {k} {kill}"))))

(ert-deftest tintin-test-indent-one-level ()
  "Line inside braces should be indented one level."
  (let ((result (tintin-test-indent "#action {pattern}\n{\ncommand\n}")))
    (should (equal result "#action {pattern}\n{\n  command\n}"))))

(ert-deftest tintin-test-indent-two-levels ()
  "Line inside two levels of braces should be indented twice."
  (let ((result (tintin-test-indent "{\n{\ndeep\n}\n}")))
    (should (equal result "{\n  {\n    deep\n  }\n}"))))

(ert-deftest tintin-test-indent-closing-brace ()
  "Closing brace should dedent to match opening level."
  (let ((result (tintin-test-indent "{\ninner\n}")))
    (should (equal result "{\n  inner\n}"))))

(ert-deftest tintin-test-indent-custom-offset ()
  "Should respect tintin-indent-offset."
  (let ((tintin-indent-offset 4))
    (let ((result (tintin-test-indent "{\ninner\n}")))
      (should (equal result "{\n    inner\n}")))))

;;; tintin-mode-tests.el ends here

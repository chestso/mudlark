;; tests/tintin-parsing.lisp - Tests for argument and command parsing
(load "tests/test-loader.lisp")

;; ============================================================================
;; tintin-split-commands - basic splitting
;; ============================================================================
(assert-equal (tintin-split-commands "n;s;e") '("n" "s" "e")
 "split-commands basic semicolons")
(assert-equal (tintin-split-commands "single") '("single")
 "split-commands single command")
(assert-nil (tintin-split-commands "") "split-commands empty string")

;; ============================================================================
;; tintin-split-commands - brace awareness
;; ============================================================================
(assert-equal (tintin-split-commands "#alias {go} {n;s;e}")
 '("#alias {go} {n;s;e}") "split-commands braces protect semicolons")
(assert-equal (tintin-split-commands "a;{b;c};d") '("a" "{b;c}" "d")
 "split-commands mixed braces and bare")

;; ============================================================================
;; tintin-extract-braced
;; ============================================================================
(let ((result (tintin-extract-braced "{hello}" 0)))
  (assert-equal (car result) "{hello}" "extract-braced simple text")
  (assert-equal (cdr result) 7 "extract-braced end pos"))

;; Nested braces
(let ((result (tintin-extract-braced "{a{b}c}" 0)))
  (assert-equal (car result) "{a{b}c}" "extract-braced nested")
  (assert-equal (cdr result) 7 "extract-braced nested end pos"))

;; With leading text
(let ((result (tintin-extract-braced "cmd {arg}" 0)))
  (assert-equal (car result) "{arg}" "extract-braced skips leading text")
  (assert-equal (cdr result) 9 "extract-braced after skip end pos"))

;; No braces
(assert-nil (tintin-extract-braced "no braces" 0)
 "extract-braced returns nil when no braces")

;; Unclosed brace at top level
(assert-equal (tintin-extract-braced "{unclosed" 0) 'unclosed
 "extract-braced returns 'unclosed when opening brace has no match")

;; Unclosed nested brace
(assert-equal (tintin-extract-braced "{a{b}c" 0) 'unclosed
 "extract-braced returns 'unclosed when nested closer is missing")

;; ============================================================================
;; tintin-parse-arguments
;; ============================================================================
(assert-equal (tintin-parse-arguments "#alias bag {kill %1}" 2)
 '("bag" "{kill %1}") "parse-arguments mixed unbraced+braced")
(assert-equal (tintin-parse-arguments "#load Det" 1)
 '("Det") "parse-arguments single unbraced")
(assert-equal (tintin-parse-arguments "#highlight {red} {orc}" 2)
 '("{red}" "{orc}") "parse-arguments two braced")

;; Unclosed brace propagates as 'unclosed
(assert-equal (tintin-parse-arguments "#alias a {bad" 2) 'unclosed
 "parse-arguments returns 'unclosed when a braced arg is unclosed")
(assert-equal (tintin-parse-arguments "#highlight {red} {bad" 2) 'unclosed
 "parse-arguments returns 'unclosed when later braced arg is unclosed")
(assert-nil (tintin-parse-arguments "#alias" 2)
 "parse-arguments still returns nil when there are simply too few args")

;; ============================================================================
;; tintin-expand-variables-fast - forward port-walk parity
;; ============================================================================
(hash-set! *tintin-variables* "target" "orc")
(hash-set! *tintin-variables* "n" "north")

(assert-equal (tintin-expand-variables-fast "kill $target") "kill orc"
 "expand-variables basic substitution")
(assert-equal (tintin-expand-variables-fast "no vars here") "no vars here"
 "expand-variables passes literal text through")
(assert-equal (tintin-expand-variables-fast "$target and $n") "orc and north"
 "expand-variables multiple variables")
(assert-equal (tintin-expand-variables-fast "go $target now") "go orc now"
 "expand-variables variable in the middle")
;; Unset variable keeps the literal $name
(assert-equal (tintin-expand-variables-fast "$missing") "$missing"
 "expand-variables unset var keeps literal")
;; A lone trailing $ stays literal
(assert-equal (tintin-expand-variables-fast "cost is 5$") "cost is 5$"
 "expand-variables trailing $ stays literal")
;; $$ - neither is a name, both stay literal
(assert-equal (tintin-expand-variables-fast "a$$b") "a$$b"
 "expand-variables doubled $ stays literal")
;; Name terminates at a non-varname char ('-' and '_' ARE name chars)
(assert-equal (tintin-expand-variables-fast "$target!") "orc!"
 "expand-variables name ends at punctuation")

;; tintin-parsing.lisp - Argument and command parsing for TinTin++ emulator
;;
;; Depends on: tintin-state.lisp, tintin-utils.lisp
;; ============================================================================
;; COMMAND SPLITTING
;; ============================================================================
;; Check if character is a digit
(defun tintin-is-digit? (ch)
  (and (string? ch) (= (length ch) 1)
       (or (string=? ch "0") (string=? ch "1") (string=? ch "2")
           (string=? ch "3") (string=? ch "4") (string=? ch "5")
           (string=? ch "6") (string=? ch "7") (string=? ch "8")
           (string=? ch "9"))))

;; Recursive helper for splitting commands
(defun tintin-split-loop (str pos len depth current results)
  (if (>= pos len)
    ;; Done - add final command if any and return reversed list
    (if (not (string=? current ""))
      (reverse (cons current results))
      (reverse results))
    ;; Process current character
    (let ((ch (string-ref str pos)))
      (cond
        ((char=? ch #\{)
         (tintin-split-loop str (+ pos 1) len (+ depth 1)
          (concat current (char->string ch)) results))
        ((char=? ch #\})
         (tintin-split-loop str (+ pos 1) len (- depth 1)
          (concat current (char->string ch)) results))
        ((and (char=? ch #\;) (= depth 0))
         (tintin-split-loop str (+ pos 1) len depth "" (cons current results)))
        (#t
         (tintin-split-loop str (+ pos 1) len depth
          (concat current (char->string ch)) results))))))

(defun tintin-split-commands (str)
  "Split command string by semicolons, respecting brace nesting.

  ## Parameters
  - `str` - Command string potentially containing multiple commands

  ## Returns
  List of trimmed command strings. Returns empty list `()` if string is invalid.

  ## Description
  Splits input by semicolons (`;`) into individual commands while respecting
  brace nesting. Semicolons inside braces are NOT treated as separators.

  ## Examples
  ```lisp
  (tintin-split-commands \"n;s;e\")
  ; => (\"n\" \"s\" \"e\")

  (tintin-split-commands \"#alias {go} {n;s;e}\")
  ; => (\"#alias {go} {n;s;e}\")
  ```"
  (if (not (string? str))
    '()
    ;; Split commands and trim whitespace from each
    (map tintin-trim (tintin-split-loop str 0 (length str) 0 "" '()))))

;; ============================================================================
;; BRACED ARGUMENT EXTRACTION
;; ============================================================================
;; Extract braced argument (including braces)
;; Returns (braced-text . next-pos) or nil if no braced text found
;; Example: "{hello {world}}" → ("{hello {world}}" . position-after-closing-brace)
(defun tintin-extract-braced (str start-pos)
  "Extract brace-delimited text with nesting support.

  ## Parameters
  - `str` - String to extract from
  - `start-pos` - Position to start scanning (0-based index)

  ## Returns
  Cons cell `(braced-text . next-pos)` where:
  - `braced-text` - Extracted text **including outer braces**
  - `next-pos` - Position immediately after closing brace

  Returns `nil` if no braced text found."
  (if (>= start-pos (length str))
    nil
    (let ((pos start-pos)
          (len (length str)))
      ;; Find opening brace
      (do ()
        ((or (>= pos len) (char=? (string-ref str pos) #\{))
         (if (>= pos len)
           nil
           ;; Extract including braces - track depth for nested braces
           (let ((depth 1)
                 (brace-start pos) ; Start at opening brace
                 (end-pos (+ pos 1)))
             (do ()
               ((or (>= end-pos len) (= depth 0))
                (if (= depth 0)
                  ;; Return text INCLUDING braces (from brace-start to end-pos)
                  (cons (substring str brace-start end-pos) end-pos)
                  'unclosed))
               (let ((ch (string-ref str end-pos)))
                 (if (char=? ch #\{)
                   (set! depth (+ depth 1))
                   (if (char=? ch #\}) (set! depth (- depth 1))))
                 (set! end-pos (+ end-pos 1)))))))
        (set! pos (+ pos 1))))))

;; Extract space-delimited token starting at pos
;; Returns (token . next-pos) or nil if no token found
;; Example: (tintin-extract-token "#load Det" 6) => ("Det" . 9)
(defun tintin-extract-token (str start-pos)
  (if (>= start-pos (length str))
    nil
    (let ((len (length str))
          (pos start-pos))
      ;; Skip leading whitespace
      (do () ((or (>= pos len) (not (char=? (string-ref str pos) #\space))))
        (set! pos (+ pos 1)))
      ;; Check if we have any characters left
      (if (>= pos len)
        nil
        ;; Find end of token (space or end of string)
        (let ((start pos)
              (end pos))
          (do () ((or (>= end len) (char=? (string-ref str end) #\space)))
            (set! end (+ end 1)))
          ;; Return token and position
          (if (= start end) nil (cons (substring str start end) end)))))))

;; Extract from start-pos to end of string (for last argument in unbraced format)
;; Returns: (string . end-pos) or nil
(defun tintin-extract-to-end (str start-pos)
  (if (>= start-pos (length str))
    nil
    (let ((len (length str))
          (pos start-pos))
      ;; Skip leading whitespace
      (do () ((or (>= pos len) (not (char=? (string-ref str pos) #\space))))
        (set! pos (+ pos 1)))
      ;; Check if we have any characters left
      (if (>= pos len)
        nil
        ;; Return from pos to end of string
        (cons (substring str pos len) len)))))

;; ============================================================================
;; ARGUMENT PARSING
;; ============================================================================
;; Parse N arguments from command string (mixed format: braced or unbraced)
;; Returns: list of N strings or nil if parsing fails
;; Each argument can be independently braced or unbraced
;; Braced arguments preserve braces: {text} → "{text}"
;; Example: (tintin-parse-arguments "#alias bag {kill %1}" 2) => ("bag" "{kill %1}")
;;          (tintin-parse-arguments "#load Det" 1) => ("Det")
(defun tintin-parse-arguments (input n)
  "Parse N arguments from TinTin++ command string (mixed braced/unbraced format).

  ## Parameters
  - `input` - TinTin++ command string (starting with `#`)
  - `n` - Number of arguments to extract

  ## Returns
  List of `n` argument strings (braced args include braces), or `nil` if
  parsing fails (insufficient arguments or invalid syntax).

  ## Examples
  ```lisp
  (tintin-parse-arguments \"#alias bag {kill %1}\" 2)
  ; => (\"bag\" \"{kill %1}\")

  (tintin-parse-arguments \"#load path/to/file.lisp\" 1)
  ; => (\"path/to/file.lisp\")
  ```"
  (let ((start-pos 1) ; Start after #
        (args '())
        (success #t)
        (reason nil))
    ;; Step 1: Skip whitespace after #
    (do ()
      ((or (>= start-pos (length input))
           (not (char=? (string-ref input start-pos) #\space))))
      (set! start-pos (+ start-pos 1)))
    ;; Step 2: Skip past command name (until space, {, or end)
    (do ()
      ((or (>= start-pos (length input))
           (char=? (string-ref input start-pos) #\space)
           (char=? (string-ref input start-pos) #\{)))
      (set! start-pos (+ start-pos 1)))
    ;; Step 3: Parse N arguments using mixed format
    ;; Each argument can be braced or unbraced independently
    (do ((i 0 (+ i 1)))
      ((or (>= i n) (not success))
       (cond (success (reverse args)) (reason reason) (#t nil)))
      ;; Skip whitespace before this argument
      (do ()
        ((or (>= start-pos (length input))
             (not (char=? (string-ref input start-pos) #\space))))
        (set! start-pos (+ start-pos 1)))
      ;; Check if we have more input
      (if (>= start-pos (length input))
        (set! success #f) ; Ran out of input before getting N arguments
        ;; Check if this argument is braced or unbraced
        (let ((is-braced (char=? (string-ref input start-pos) #\{)))
          (if is-braced
            ;; Extract braced argument (preserves braces)
            (let ((arg-data (tintin-extract-braced input start-pos)))
              (cond
                ((eq? arg-data 'unclosed)
                 (set! reason 'unclosed) (set! success #f))
                (arg-data (set! args (cons (car arg-data) args))
                 (set! start-pos (cdr arg-data)))
                (#t (set! success #f))))
            ;; Extract unbraced token
            ;; For the last argument, read to end of string instead of stopping at space
            (let ((is-last-arg (= i (- n 1))))
              (let ((token-data
                     (if is-last-arg
                       (tintin-extract-to-end input start-pos)
                       (tintin-extract-token input start-pos))))
                (if token-data
                  (progn (set! args (cons (car token-data) args))
                    (set! start-pos (cdr token-data)))
                  (set! success #f))))))))))

;; ============================================================================
;; VARIABLE EXPANSION
;; ============================================================================
;; Expand $variable references in a string (optimized O(m) single-pass)
(defun tintin-expand-variables-fast (str)
  "Expand $variable references in string (optimized O(m) single-pass version).

  ## Parameters
  - `str` - String potentially containing $variable references

  ## Returns
  String with all $variable references replaced by their values.

  ## Examples
  ```lisp
  (hash-set! *tintin-variables* \"target\" \"orc\")
  (tintin-expand-variables-fast \"kill $target\")
  ; => \"kill orc\"
  ```"
  (if (not (string? str))
    str
    (let ((len (length str))
          (pos 0)
          (result ""))
      (do () ((>= pos len) result)
        (let ((ch (string-ref str pos)))
          (if (char=? ch #\$)
            ;; Extract variable name
            (let ((var-start (+ pos 1))
                  (var-end (+ pos 1)))
              ;; Find end of variable name
              (do ()
                ((or (>= var-end len)
                     (not (tintin-is-varname-char? (string-ref str var-end)))))
                (set! var-end (+ var-end 1)))
              (if (= var-start var-end)
                ;; No variable name after $, keep literal $
                (progn (set! result (concat result "$")) (set! pos (+ pos 1)))
                ;; Variable name found, try to expand
                (let* ((var-name (substring str var-start var-end))
                       (var-value (hash-ref *tintin-variables* var-name)))
                  (if var-value
                    (set! result (concat result var-value))
                    (set! result (concat result "$" var-name)))
                  (set! pos var-end))))
            ;; Regular character
            (progn (set! result (concat result (char->string ch)))
              (set! pos (+ pos 1)))))))))

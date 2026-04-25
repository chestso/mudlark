;; tintin-commands.lisp - Command handlers and dispatcher for TinTin++ emulator
;;
;; Depends on: tintin-state.lisp, tintin-utils.lisp, tintin-colors.lisp,
;;             tintin-parsing.lisp, tintin-tables.lisp, tintin-save.lisp
;; ============================================================================
;; COMMAND DETECTION
;; ============================================================================
;; Check if a string is a TinTin++ command (starts with #)
(defun tintin-is-command? (str)
  (and (string? str) (> (length str) 0) (char=? (string-ref str 0) #\#)))

;; Extract command name from TinTin++ command string
;; Example: "#alias {k} {kill}" → "alias"
;;          "#var{x}" → "var"
;;          "# " → nil
(defun tintin-extract-command-name (str)
  (if (not (tintin-is-command? str))
    nil
    (let ((len (length str))
          (pos 1))
      ;; Skip any whitespace after #
      (do () ((or (>= pos len) (not (char=? (string-ref str pos) #\space))))
        (set! pos (+ pos 1)))
      ;; Check if we have any characters left
      (if (>= pos len)
        nil
        ;; Find end of command word (space, {, or end of string)
        (let ((start pos)
              (end pos))
          (do ()
            ((or (>= end len) (char=? (string-ref str end) #\space)
                 (char=? (string-ref str end) #\{)))
            (set! end (+ end 1)))
          ;; Extract and lowercase the command name
          (if (= start end) nil (string-downcase (substring str start end))))))))

;; Find a TinTin++ command by partial prefix match
;; Returns the full command name or nil if no match
;; Example: "al" → "alias", "var" → "variable"
(defun tintin-find-command (prefix)
  "Find TinTin++ command by exact match first, then partial prefix (case-insensitive)."
  (if (not (string? prefix))
    nil
    (let ((prefix-lower (string-downcase prefix)))
      ;; First: exact match (O(1) hash lookup)
      (if (hash-ref *tintin-commands* prefix-lower)
        prefix-lower
        ;; Then: prefix match (linear scan)
        (let ((commands (hash-keys *tintin-commands*))
              (result nil))
          (do ((i 0 (+ i 1))) ((or (>= i (length commands)) result) result)
            (let ((cmd (list-ref commands i)))
              (if (string-prefix? prefix-lower cmd) (set! result cmd)))))))))

;; ============================================================================
;; COMMAND ECHO (suppressed during #read)
;; ============================================================================
(defun tintin-command-echo (msg)
  "Echo a command confirmation, suppressed during #read file loading."
  (if (not *tintin-reading-file*) (terminal-echo msg)))

(defun tintin-echo (msg)
  (terminal-echo (concat "\r\n\033[36m[🐈 Tintin]\033[0m " msg "\r\n")))

(defun tintin-error-echo (msg)
  (terminal-echo (concat "\r\n\033[31m[🐈 Tintin]\033[0m " msg "\r\n")))

;; ============================================================================
;; COMMAND HANDLERS
;; ============================================================================
;; Handle #alias command
;; args: (), (name), or (name commands)
(defun tintin-handle-alias (args)
  "Handle #alias command (list, show, or create aliases)."
  (cond
    ;; No arguments - list all aliases
    ((or (null? args) (= 0 (length args))) (tintin-list-aliases))
    ;; One argument - show specific alias
    ((= 1 (length args))
     (let ((name (tintin-strip-braces (list-ref args 0))))
       (let ((alias-data (hash-ref *tintin-aliases* name)))
         (if alias-data
           (let ((commands (car alias-data))
                 (priority (cadr alias-data)))
             (tintin-command-echo
              (concat "Alias '" name "': " name " → " commands
               (if (= priority 5)
                 ""
                 (concat " (priority: " (number->string priority) ")")) "\r\n"))
             "")
           (progn (terminal-echo (concat "Alias '" name "' not found\r\n")) "")))))
    ;; Two arguments - create alias
    (#t
     (let ((name (tintin-strip-braces (list-ref args 0)))
           (commands (tintin-strip-braces (list-ref args 1)))
           (priority 5))
       (hash-set! *tintin-aliases* name (list commands priority))
       (tintin-command-echo
        (concat "Alias '" name "' created: " name " → " commands
         (if (= priority 5)
           ""
           (concat " (priority: " (number->string priority) ")")) "\r\n"))
       ""))))

;; Handle #variable command
;; args: (), (name), or (name value)
(defun tintin-handle-variable (args)
  "Handle #variable command (list, show, or create variables)."
  (cond
    ;; No arguments - list all variables
    ((or (null? args) (= 0 (length args))) (tintin-list-variables))
    ;; One argument - show specific variable
    ((= 1 (length args))
     (let ((name (tintin-strip-braces (list-ref args 0))))
       (let ((value (hash-ref *tintin-variables* name)))
         (if value
           (progn
             (tintin-command-echo
              (concat "Variable '" name "': " name " = " value "\r\n"))
             "")
           (progn (terminal-echo (concat "Variable '" name "' not found\r\n"))
             "")))))
    ;; Two arguments - create variable
    (#t
     (let ((name (tintin-strip-braces (list-ref args 0)))
           (value (tintin-strip-braces (list-ref args 1))))
       (hash-set! *tintin-variables* name value)
       (tintin-command-echo
        (concat "Variable '" name "' set to '" value "'\r\n"))
       ""))))

;; Handle #unalias command
;; args: (name)
(defun tintin-handle-unalias (args)
  "Handle #unalias command (remove alias)."
  (let ((name (tintin-strip-braces (list-ref args 0))))
    (if (hash-ref *tintin-aliases* name)
      (progn (hash-remove! *tintin-aliases* name)
        (tintin-command-echo (concat "Alias '" name "' removed\r\n"))
        "")
      (progn (terminal-echo (concat "Alias '" name "' not found\r\n")) ""))))

;; Handle #highlight command
;; args: (), (pattern), (pattern color), or (pattern color priority)
;; Color spec format: "fg", "fg:bg", "<rgb>", "bold red", etc.
;; Entry format: pattern → (fg-color bg-color priority)
(defun tintin-handle-highlight (args)
  "Handle #highlight command (list, show, or create highlights)."
  (cond
    ;; No arguments - list all highlights
    ((or (null? args) (= 0 (length args))) (tintin-list-highlights))
    ;; One argument - show specific highlight
    ((= 1 (length args))
     (let ((pattern (tintin-strip-braces (list-ref args 0))))
       (let ((highlight-data (hash-ref *tintin-highlights* pattern)))
         (if highlight-data
           (let ((fg-color (car highlight-data))
                 (bg-color (cadr highlight-data))
                 (priority (caddr highlight-data)))
             (tintin-command-echo
              (concat "Highlight '" pattern "': " pattern " → "
               (if fg-color fg-color "") (if (and fg-color bg-color) ":" "")
               (if bg-color bg-color "")
               (if (= priority 5)
                 ""
                 (concat " (priority: " (number->string priority) ")")) "\r\n"))
             "")
           (progn
             (terminal-echo (concat "Highlight '" pattern "' not found\r\n"))
             "")))))
    ;; Two or three arguments - create highlight
    (#t
     (let* ((pattern (tintin-strip-braces (list-ref args 0)))
            (color-spec (tintin-strip-braces (list-ref args 1)))
            (priority
             (if (>= (length args) 3)
               (string->number (tintin-strip-braces (list-ref args 2)))
               5)))
       ;; Parse color spec into FG and BG components
       (let ((parts (tintin-split-fg-bg color-spec)))
         (let ((fg-part (list-ref parts 0))
               (bg-part (list-ref parts 1)))
           ;; Store as (fg-color bg-color priority)
           (hash-set! *tintin-highlights* pattern
            (list (if (string=? fg-part "") nil fg-part) bg-part priority))
           ;; Invalidate caches
           (set! *tintin-highlights-dirty* #t)
           (tintin-command-echo
            (concat "Highlight '" pattern "' created: " pattern " → "
             color-spec
             (if (= priority 5)
               ""
               (concat " (priority: " (number->string priority) ")")) "\r\n"))
           ""))))))

;; Handle #unhighlight command
;; args: (pattern)
(defun tintin-handle-unhighlight (args)
  (let ((pattern (tintin-strip-braces (list-ref args 0))))
    (if (hash-ref *tintin-highlights* pattern)
      (progn (hash-remove! *tintin-highlights* pattern)
        ;; Invalidate caches
        (hash-remove! *tintin-pattern-cache* pattern)
        (set! *tintin-highlights-dirty* #t)
        (tintin-command-echo (concat "Highlight '" pattern "' removed\r\n"))
        "")
      (progn (terminal-echo (concat "Highlight '" pattern "' not found\r\n"))
        ""))))

;; Handle #action command
;; args: (), (pattern), (pattern commands), or (pattern commands priority)
;; Entry format: pattern → (commands-string priority)
(defun tintin-handle-action (args)
  "Handle #action command (list, show, or create triggers)."
  (cond
    ;; No arguments - list all actions
    ((or (null? args) (= 0 (length args))) (tintin-list-actions))
    ;; One argument - show specific action
    ((= 1 (length args))
     (let ((pattern (tintin-strip-braces (list-ref args 0))))
       (let ((action-data (hash-ref *tintin-actions* pattern)))
         (if action-data
           (let ((commands (car action-data))
                 (priority (cadr action-data)))
             (tintin-command-echo
              (concat "Action '" pattern "': " pattern " → " commands
               (if (= priority 5)
                 ""
                 (concat " (priority: " (number->string priority) ")")) "\r\n"))
             "")
           (progn (terminal-echo (concat "Action '" pattern "' not found\r\n"))
             "")))))
    ;; Two or three arguments - create action
    (#t
     (let* ((pattern (tintin-strip-braces (list-ref args 0)))
            (commands (tintin-strip-braces (list-ref args 1)))
            (priority
             (if (>= (length args) 3)
               (string->number (tintin-strip-braces (list-ref args 2)))
               5)))
       ;; Store as (commands-string priority)
       (hash-set! *tintin-actions* pattern (list commands priority))
       (tintin-command-echo
        (concat "Action '" pattern "' created: " pattern " → " commands
         (if (= priority 5)
           ""
           (concat " (priority: " (number->string priority) ")")) "\r\n"))
       ""))))

;; Handle #unaction command
;; args: (pattern)
(defun tintin-handle-unaction (args)
  (let ((pattern (tintin-strip-braces (list-ref args 0))))
    (if (hash-ref *tintin-actions* pattern)
      (progn (hash-remove! *tintin-actions* pattern)
        (tintin-command-echo (concat "Action '" pattern "' removed\r\n"))
        "")
      (progn (terminal-echo (concat "Action '" pattern "' not found\r\n")) ""))))

;; Handle #color command (bloom extension, not in upstream TinTin++)
;; args: (), (name), or (name spec)
(defun tintin-handle-color (args)
  "Handle #color command (list, show, or create custom named colors)."
  (cond
    ;; No arguments - list all custom colors
    ((or (null? args) (= 0 (length args))) (tintin-list-colors))
    ;; One argument - show specific color
    ((= 1 (length args))
     (let ((name (tintin-strip-braces (list-ref args 0))))
       (let ((spec (hash-ref *tintin-custom-colors* name)))
         (if spec
           (let* ((parsed (tintin-parse-color-spec spec))
                  (fg-codes (car parsed))
                  (bg-codes (cadr parsed))
                  (ansi-open (tintin-build-ansi-code fg-codes bg-codes))
                  (preview (concat ansi-open "sample" "\033[0m")))
             (tintin-command-echo
              (concat "Color '" name "': " spec " " preview "\r\n"))
             "")
           (progn (terminal-echo (concat "Color '" name "' not found\r\n")) "")))))
    ;; Two arguments - create custom color
    (#t
     (let ((name (tintin-strip-braces (list-ref args 0)))
           (spec (tintin-strip-braces (list-ref args 1))))
       (hash-set! *tintin-custom-colors* name spec)
       (let* ((parsed (tintin-parse-color-spec spec))
              (fg-codes (car parsed))
              (bg-codes (cadr parsed))
              (ansi-open (tintin-build-ansi-code fg-codes bg-codes))
              (preview (concat ansi-open "sample" "\033[0m")))
         (tintin-command-echo
          (concat "Color '" name "' set to '" spec "' " preview "\r\n"))
         "")))))

;; Handle #uncolor command
;; args: (name)
(defun tintin-handle-uncolor (args)
  "Handle #uncolor command (remove custom named color)."
  (let ((name (tintin-strip-braces (list-ref args 0))))
    (if (hash-ref *tintin-custom-colors* name)
      (progn (hash-remove! *tintin-custom-colors* name)
        (tintin-command-echo (concat "Color '" name "' removed\r\n"))
        "")
      (progn (terminal-echo (concat "Color '" name "' not found\r\n")) ""))))

;; Handle #config command (matches upstream TinTin++ #config)
;; args: (), (setting), or (setting value)
;; Supported settings: "speedwalk", "speedwalk diagonals" (bloom extension)
(defun tintin-handle-config (args)
  "Handle #config command (list, show, or set configuration)."
  (cond
    ;; No arguments - list all settings
    ((or (null? args) (= 0 (length args)))
     (tintin-command-echo "Configuration:\r\n")
     (tintin-command-echo
      (concat "  speedwalk           "
       (if *tintin-speedwalk-enabled* "on" "off") "\r\n"))
     (tintin-command-echo
      (concat "  speedwalk diagonals "
       (if *tintin-speedwalk-diagonals* "on" "off") "\r\n")) "")
    ;; One argument - show specific setting
    ((= 1 (length args))
     (let ((key (string-downcase (tintin-strip-braces (list-ref args 0)))))
       (cond
         ((string=? key "speedwalk")
          (tintin-command-echo
           (concat "speedwalk = " (if *tintin-speedwalk-enabled* "on" "off")
            "\r\n")) "")
         ((string=? key "speedwalk diagonals")
          (tintin-command-echo
           (concat "speedwalk diagonals = "
            (if *tintin-speedwalk-diagonals* "on" "off") "\r\n")) "")
         (#t (terminal-echo (concat "Unknown config: " key "\r\n")) ""))))
    ;; Two arguments - set a setting
    (#t
     (let ((key (string-downcase (tintin-strip-braces (list-ref args 0))))
           (val (string-downcase (tintin-strip-braces (list-ref args 1)))))
       (let ((bool-val
              (cond
                ((string=? val "on") #t)
                ((string=? val "off") #f)
                (#t nil))))
         (if (not (or (string=? val "on") (string=? val "off")))
           (progn
             (terminal-echo (concat "Invalid value: " val " (use on/off)\r\n"))
             "")
           (cond
             ((string=? key "speedwalk")
              (set! *tintin-speedwalk-enabled* bool-val)
              (tintin-command-echo
               (concat "speedwalk = " (if bool-val "on" "off") "\r\n")) "")
             ((string=? key "speedwalk diagonals")
              (set! *tintin-speedwalk-diagonals* bool-val)
              (tintin-command-echo
               (concat "speedwalk diagonals = " (if bool-val "on" "off") "\r\n")) "")
             (#t (terminal-echo (concat "Unknown config: " key "\r\n")) ""))))))))

;; ============================================================================
;; COMMAND REGISTRY
;; ============================================================================
;; Register commands with metadata (now that handlers are defined)
(hash-set! *tintin-commands* "alias"
 (list tintin-handle-alias 2
  "#alias or #alias {name} or #alias {name} {commands}"))
(hash-set! *tintin-commands* "unalias"
 (list tintin-handle-unalias 1 "#unalias {name}"))
(hash-set! *tintin-commands* "variable"
 (list tintin-handle-variable 2
  "#variable or #variable {name} or #variable {name} {value}"))
(hash-set! *tintin-commands* "highlight"
 (list tintin-handle-highlight 2
  "#highlight or #highlight {pattern} or #highlight {pattern} {color}"))
(hash-set! *tintin-commands* "unhighlight"
 (list tintin-handle-unhighlight 1 "#unhighlight {pattern}"))
(hash-set! *tintin-commands* "color"
 (list tintin-handle-color 2 "#color or #color {name} or #color {name} {spec}"))
(hash-set! *tintin-commands* "uncolor"
 (list tintin-handle-uncolor 1 "#uncolor {name}"))
(hash-set! *tintin-commands* "write"
 (list tintin-handle-write 1 "#write {filename}"))
(hash-set! *tintin-commands* "config"
 (list tintin-handle-config 2
  "#config or #config {setting} or #config {setting} {on|off}"))
(hash-set! *tintin-commands* "action"
 (list tintin-handle-action 3
  "#action or #action {pattern} or #action {pattern} {commands} [priority]"))
(hash-set! *tintin-commands* "unaction"
 (list tintin-handle-unaction 1 "#unaction {pattern}"))

;; ============================================================================
;; GENERIC COMMAND DISPATCHER
;; ============================================================================
;; Check if a TinTin++ command has any arguments
;; Returns #t if arguments present, #f if just command name
(defun tintin-has-arguments? (input)
  (let ((len (length input))
        (pos 1))
    ;; Skip whitespace after #
    (do () ((or (>= pos len) (not (char=? (string-ref input pos) #\space))))
      (set! pos (+ pos 1)))
    ;; Skip command name
    (do ()
      ((or (>= pos len) (char=? (string-ref input pos) #\space)
           (char=? (string-ref input pos) #\{)))
      (set! pos (+ pos 1)))
    ;; Skip whitespace after command name
    (do () ((or (>= pos len) (not (char=? (string-ref input pos) #\space))))
      (set! pos (+ pos 1)))
    ;; If we have more characters, there are arguments
    (< pos len)))

;; Try parsing with progressively fewer arguments (for variable-arg commands)
;; Returns parsed args list or nil if all attempts fail
(defun tintin-try-parse-arguments (input max-count)
  (if (<= max-count 0)
    nil
    (let ((args (tintin-parse-arguments input max-count)))
      (cond
        ((eq? args 'unclosed) 'unclosed)
        (args args)
        (#t (tintin-try-parse-arguments input (- max-count 1)))))))

;; Dispatch a TinTin++ command using metadata-driven approach
;; cmd-name: matched command name (e.g., "alias")
;; input: original input string (e.g., "#alias {k} {kill %1}")
(defun tintin-dispatch-command (cmd-name input)
  (let ((cmd-data (hash-ref *tintin-commands* cmd-name)))
    (if (not cmd-data)
      ;; Should never happen (tintin-find-command validated it)
      ""
      (let ((handler (list-ref cmd-data 0))
            (arg-count (list-ref cmd-data 1))
            (syntax-help (list-ref cmd-data 2)))
        ;; Check if input has any arguments after command name
        (let ((has-args (tintin-has-arguments? input)))
          (if (not has-args)
            ;; No arguments - call handler with empty list
            (handler '())
            ;; Has arguments - try parsing with max count down to 1
            (let ((args (tintin-try-parse-arguments input arg-count)))
              (cond
                ((eq? args 'unclosed)
                 (tintin-error-echo
                  (concat "Syntax error: unclosed brace in: " input))
                 "")
                (args (handler args))
                (#t (tintin-error-echo (concat "Syntax error: " syntax-help))
                 "")))))))))

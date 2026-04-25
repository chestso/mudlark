;; tintin.lisp - TinTin++ emulator for bloom-telnet
;;
;; This is the main entry point that loads all TinTin++ modules and
;; provides the input processing hooks for the telnet client.
;;
;; ## Module Load Order
;;
;; Modules must be loaded in dependency order:
;; 1. tintin-state.lisp    - Global state and constants (no dependencies)
;; 2. tintin-utils.lisp    - Core utilities (depends on state)
;; 3. tintin-colors.lisp   - Color parsing (depends on state, utils)
;; 4. tintin-patterns.lisp - Pattern matching (depends on state)
;; 5. tintin-parsing.lisp  - Argument parsing (depends on state, utils)
;; 6. tintin-speedwalk.lisp - Speedwalk expansion (depends on state, parsing)
;; 7. tintin-highlights.lisp - Highlight application (depends on state, colors, patterns)
;; 8. tintin-actions.lisp  - Action triggering (depends on state, utils, patterns, parsing)
;; 9. tintin-aliases.lisp  - Alias expansion (depends on state, utils, patterns, parsing, speedwalk)
;; 10. tintin-tables.lisp  - Table formatting (depends on state, utils)
;; 11. tintin-save.lisp    - Save/load (depends on state, utils)
;; 12. tintin-commands.lisp - Command handlers (depends on all above)
;; 13. tintin-read.lisp     - #read config file loader (depends on commands, parsing)
;;
;; ============================================================================
;; LOAD MODULES
;; ============================================================================
;; Use load-system-file to search in standard lisp directories
(load-system-file "tintin-state.lisp")
(load-system-file "tintin-utils.lisp")
(load-system-file "tintin-colors.lisp")
(load-system-file "tintin-patterns.lisp")
(load-system-file "tintin-parsing.lisp")
(load-system-file "tintin-speedwalk.lisp")
(load-system-file "tintin-highlights.lisp")
(load-system-file "tintin-actions.lisp")
(load-system-file "tintin-aliases.lisp")
(load-system-file "tintin-tables.lisp")
(load-system-file "tintin-save.lisp")
(load-system-file "tintin-commands.lisp")
(load-system-file "tintin-read.lisp")

;; ============================================================================
;; INPUT PROCESSING
;; ============================================================================
;; Main command router with depth tracking via *tintin-alias-depth*.
;;
;; Each iteration:
;; 1. Check depth limit — if exceeded, error and pass through
;; 2. Run filter hook — if consumed, done
;; 3. Check for # command — if so, dispatch, done
;; 4. Try one level of alias expansion — if no match, return command (to server)
;; 5. If alias matched — send expanded parts via send-input (re-enters event loop)
(defun tintin-process-command-internal (cmd)
  (if (or (not (string? cmd)) (string=? cmd ""))
    ""
    ;; Depth check (for alias expansion chains via send-input)
    (if (>= *tintin-alias-depth* *tintin-max-alias-depth*)
      (progn
        (terminal-echo
         (concat "Error: Circular alias detected or depth limit ("
          (number->string *tintin-max-alias-depth*) ") exceeded\r\n"))
        cmd)
      ;; Filter hook — may consume (e.g. /greet). When consumed inside an
      ;; alias expansion, still echo the expanded leaf so the user can see
      ;; what their alias produced regardless of which hook swallowed it.
      (if (not (run-filter-hook 'user-input-hook cmd))
        (progn
          (when (> *tintin-alias-depth* 0)
            (let ((server-cmd
                   (tintin-expand-speedwalk
                    (tintin-expand-variables-fast cmd))))
              (when (not (string=? server-cmd ""))
                (terminal-echo (concat server-cmd "\r\n")))))
          "")
        ;; Check if it's a # command
        (if (tintin-is-command? cmd)
          ;; TinTin++ command - dispatch (main.c handles echoing)
          (let ((cmd-name (tintin-extract-command-name cmd)))
            (if (not cmd-name)
              (progn
                (terminal-echo
                 (concat "Invalid TinTin++ command format: " cmd "\r\n"))
                "")
              (let ((matched (tintin-find-command cmd-name)))
                (if (not matched)
                  (progn
                    (terminal-echo
                     (concat "Unknown TinTin++ command: #" cmd-name "\r\n"))
                    "")
                  (tintin-dispatch-command matched cmd)))))
          ;; Try one level of alias expansion
          (let ((expanded (tintin-try-alias cmd)))
            (if (not expanded)
              ;; No alias — expand speedwalk + variables, return to server
              ;; Echo leaf commands from alias expansion (depth > 0)
              (let ((server-cmd
                     (tintin-expand-speedwalk
                      (tintin-expand-variables-fast cmd))))
                (if
                  (and (> *tintin-alias-depth* 0)
                       (not (string=? server-cmd "")))
                  (terminal-echo (concat server-cmd "\r\n")))
                server-cmd)
              ;; Alias matched — return expanded commands (preserves ordering)
              (tintin-expand-alias expanded))))))))

(defun tintin-process-command (cmd)
  "Process a single TinTin++ command or server command.

  ## Parameters
  - `cmd` - Command string to process

  ## Returns
  - For TinTin++ commands (#...): Empty string (handled internally)
  - For regular commands: Expanded command string (after alias substitution)"
  (tintin-process-command-internal cmd))

;; Process a full input line (split by semicolons, process each command)
(defun tintin-process-input (input)
  "Process full input line with command separation and TinTin++ expansion.

  ## Parameters
  - `input` - Full input line from user (may contain multiple commands)

  ## Returns
  Semicolon-separated string of expanded commands ready to send to server."
  (if (not (string? input))
    ""
    (let ((commands (tintin-split-commands input))
          (results '()))
      ;; Process each command and collect results
      (do ((i 0 (+ i 1))) ((>= i (length commands)))
        (let ((processed (tintin-process-command (list-ref commands i))))
          (if (and (string? processed) (not (string=? processed "")))
            (set! results (cons processed results)))))
      ;; Reverse and join results with semicolons
      (let ((reversed-results (reverse results))
            (output ""))
        (do ((i 0 (+ i 1))) ((>= i (length reversed-results)) output)
          (set! output
           (concat output (if (> i 0) ";" "") (list-ref reversed-results i))))))))

;; ============================================================================
;; USER INPUT HOOK
;; ============================================================================
;; Hook function for user-input-transform-hook integration
;; Signature: (lambda (text) -> string|nil)
;; - text: User input text (or nil if consumed by earlier hook)
;; Returns: Expanded text (semicolon-separated), or nil if only #commands
;;
;; Pure transformer: receives text, returns transformed text.
;; C caller splits result by ';' and sends each part separately.
(defun tintin-user-input-hook (text)
  (set! *tintin-alias-depth* 0)
  (if (or (not *tintin-enabled*) (not (string? text)) (string=? text ""))
    text ;; pass through
    (let ((processed (tintin-process-input text)))
      ;; Return expanded text (or nil if only #commands/aliases were processed)
      (if (and (string? processed) (not (string=? processed "")))
        (tintin-split-commands processed)
        nil))))

;; ============================================================================
;; TOGGLE FUNCTIONS
;; ============================================================================
(defun tintin-toggle! ()
  "Toggle TinTin++ processing on or off."
  (set! *tintin-enabled* (not *tintin-enabled*))
  (terminal-echo
   (concat "TinTin++ " (if *tintin-enabled* "enabled" "disabled") "\r\n"))
  *tintin-enabled*)

(defun tintin-enable! ()
  "Enable TinTin++ processing."
  (set! *tintin-enabled* #t)
  (terminal-echo "TinTin++ enabled\r\n")
  #t)

(defun tintin-disable! ()
  "Disable TinTin++ processing."
  (set! *tintin-enabled* #f)
  (terminal-echo "TinTin++ disabled\r\n")
  #f)

;; ============================================================================
;; TELNET INPUT HOOKS
;; ============================================================================
;; Hook function for telnet-input-transform-hook integration
;; Signature: (lambda (text) -> string)
;; - text: Incoming telnet data (may contain ANSI codes)
;; Returns: Transformed text with highlights applied
;;
;; This hook receives data from the telnet server before it's displayed
;; in the terminal. We apply highlight patterns to colorize matching text.
;; After applying highlights, we post-process to handle nested ANSI states
;; so that server reset codes don't kill highlight colors.
(defun tintin-telnet-input-transform (text)
  (if (and *tintin-enabled* (> (hash-count *tintin-highlights*) 0))
    (tintin-apply-highlights text)
    text))

;; TinTin++ telnet input hook handler for triggering actions
;; This hook is called when data arrives from the telnet server
;; It sees stripped text (no ANSI codes), better for pattern matching
(defun tintin-telnet-input-hook (text)
  "Process telnet input for TinTin++ action triggering.
   Called via telnet-input-hook for each chunk of server output."
  (if
    (and *tintin-enabled* (not *tintin-action-executing*)
         (> (hash-count *tintin-actions*) 0))
    (let ((lines (tintin-split-lines text)))
      (do ((i 0 (+ i 1))) ((>= i (length lines)))
        (tintin-trigger-actions-for-line (list-ref lines i))))))

;; ============================================================================
;; AUTO-ACTIVATION
;; ============================================================================
;; Register TinTin++ hooks
(add-hook 'user-input-transform-hook 'tintin-user-input-hook)
(add-hook 'telnet-input-transform-hook 'tintin-telnet-input-transform)
(add-hook 'telnet-input-hook 'tintin-telnet-input-hook)

;; Register --tintin / -t CLI handler for loading .tin config files
(defun tintin-cli-read-handler (filename)
  (let ((path (expand-path filename)))
    (let ((prev-aliases (hash-count *tintin-aliases*))
          (prev-highlights (hash-count *tintin-highlights*))
          (prev-actions (hash-count *tintin-actions*))
          (prev-variables (hash-count *tintin-variables*))
          (prev-colors (hash-count *tintin-custom-colors*)))
      (set! *tintin-reading-file* #t)
      (condition-case err
        (progn (tintin-read-file path) (set! *tintin-reading-file* #f)
          (script-echo
           (concat "Read " path
            (tintin-read-summary (- (hash-count *tintin-aliases*) prev-aliases)
             (- (hash-count *tintin-highlights*) prev-highlights)
             (- (hash-count *tintin-actions*) prev-actions)
             (- (hash-count *tintin-variables*) prev-variables)
             (- (hash-count *tintin-custom-colors*) prev-colors)))))
        (error (set! *tintin-reading-file* #f)
         (script-echo (concat "Failed to read " path ": " (error-message err))))))))

(register-cli-handler "t" "tintin" 'tintin-cli-read-handler)

;; Announce activation (terminal is ready when this file loads via -l)
(script-echo "TinTin++ emulation active")

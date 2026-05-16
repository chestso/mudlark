;; practice.lisp - Practice mode for Carrion Fields MUD
;;
;; This script was created for Carrion Fields MUD (https://carrionfields.net/)
;; ============================================================================
;; HELP TEXT
;; ============================================================================
(defvar *practice-usage*
  "/p <command>             Start practicing a command
/p <cmd1> | <cmd2>      Alternate between commands
/p stop                  Stop practicing
/p add <pattern>         Add a retry pattern
/p remove <pattern>      Remove a retry pattern
/p patterns              List retry patterns
/p                       Show status"
  "Usage text for /practice command.")

(defvar *practice-features*
  "Features
Retries on failure
Alternates commands with | delimiter
Sleeps when mana low, wakes at 100%
Quits on hunger/thirst damage

Variables
*practice-mana-pattern*            Regex extracting mana% from prompt
*practice-mana-threshold*          Mana% below which to sleep
*practice-sleep-interval*          Seconds between sleep-mode prompt refreshes
*practice-sleep-pattern*           Message triggering immediate sleep
*practice-retry-patterns*          Patterns that trigger a retry
*practice-hunger-thirst-pattern*   Regex matching hunger/thirst damage"
  "Features and variables section for /practice help.")

;; ============================================================================
;; CONFIGURATION
;; ============================================================================
(defvar *practice-mana-pattern* "(\\d+)%m"
  "Regex pattern to extract mana percentage from prompt.")

(defvar *practice-mana-threshold* 20
  "Mana percentage below which to enter sleep mode.")

(defvar *practice-sleep-interval* 10
  "Seconds between empty sends during sleep mode to refresh prompt.")

(defvar *practice-sleep-pattern* "You don't have enough mana."
  "Pattern that triggers immediate sleep mode (spell too costly).")

(defvar *practice-retry-patterns* nil
  "List of patterns that trigger a retry of the practice command.")

(defvar *practice-hunger-thirst-pattern* "Your (hunger|thirst) \\w+ you"
  "Regex pattern that matches hunger/thirst damage messages with any verb (triggers quit).")

;; ============================================================================
;; STATE VARIABLES
;; ============================================================================
(defvar *practice-mode* nil "Whether practice mode is active.")

(defvar *practice-command* nil "List of commands being practiced.")

(defvar *practice-command-index* 0 "Index of the next command to send.")

(defvar *practice-sleep-mode* nil
  "Whether we're in sleep sub-mode (waiting for mana).")

(defvar *practice-sleep-timer* nil
  "Timer object for periodic empty sends during sleep.")

;; ============================================================================
;; HELPER FUNCTIONS
;; ============================================================================
(defun practice-echo (msg)
  "Echo a practice status message to the terminal."
  (terminal-echo (concat "\r\n\033[36m[🤹 Practice]\033[0m " msg "\r\n")))

(defun practice-send (cmd)
  "Send command through the input pipeline (handles multiline, aliases, etc.)."
  (send-input cmd))

(defun practice-extract-mana (text)
  "Extract mana percentage from prompt text. Returns number or nil."
  (let ((groups (regex-extract *practice-mana-pattern* text)))
    (if (and groups (not (null? groups))) (string->number (car groups)) nil)))

(defun practice-matches-any-pattern? (text patterns)
  "Check if text contains any of the patterns in the list."
  (if (null? patterns)
    nil
    (if (string-contains? text (car patterns))
      #t
      (practice-matches-any-pattern? text (cdr patterns)))))

(defun practice-add-retry-pattern (pattern)
  "Add a pattern to *practice-retry-patterns* if not already present."
  (if (member pattern *practice-retry-patterns*)
    (practice-echo (concat "Pattern already exists: " pattern))
    (progn
      (set! *practice-retry-patterns* (cons pattern *practice-retry-patterns*))
      (practice-echo (concat "Added retry pattern: " pattern)))))

(defun practice-remove-retry-pattern (pattern)
  "Remove a pattern from *practice-retry-patterns*."
  (if (member pattern *practice-retry-patterns*)
    (progn
      (set! *practice-retry-patterns*
       (filter (lambda (p) (not (string=? p pattern)))
        *practice-retry-patterns*))
      (practice-echo (concat "Removed retry pattern: " pattern)))
    (practice-echo (concat "Pattern not found: " pattern))))

(defun practice-list-retry-patterns ()
  "List all current retry patterns."
  (if (null? *practice-retry-patterns*)
    (practice-echo "No retry patterns configured")
    (practice-echo
     (concat "Retry patterns:\n"
      (join (map (lambda (p) (concat "  - " p)) *practice-retry-patterns*) "\n")))))

(defun practice-current-command ()
  "Return the current command to send."
  (list-ref *practice-command* *practice-command-index*))

(defun practice-advance-command ()
  "Advance to the next command in the rotation."
  (set! *practice-command-index*
   (remainder (+ *practice-command-index* 1) (length *practice-command*))))

(defun practice-parse-commands (input)
  "Parse input into a list of commands, splitting on | delimiter.
   Trims whitespace from each command."
  (let ((parts (split input "|")))
    (filter (lambda (s) (> (length s) 0)) (map string-trim parts))))

;; ============================================================================
;; CORE FUNCTIONS
;; ============================================================================
(defun practice-start (command)
  "Start practice mode with the given command string.
   Supports alternating commands with | delimiter."
  (if *practice-mode*
    (practice-echo
     (concat "Already practicing: " (join *practice-command* " | ")))
    (let ((commands (practice-parse-commands command)))
      (if (null? commands)
        (practice-echo "No commands specified")
        (progn (set! *practice-mode* #t) (set! *practice-command* commands)
          (set! *practice-command-index* 0)
          (set! *practice-sleep-mode* nil)
          (set! *practice-sleep-timer* nil)
          (status-mode-set 'practice "🤹" 20)
          (practice-send (practice-current-command))
          (practice-advance-command))))))

(defun practice-stop ()
  "Stop practice mode."
  (if (not *practice-mode*)
    (practice-echo "Not currently practicing")
    (progn
      ;; Cancel timer if active
      (if *practice-sleep-timer*
        (progn (cancel-timer *practice-sleep-timer*)
          (set! *practice-sleep-timer* nil)))
      ;; Clear state
      (set! *practice-mode* nil)
      (set! *practice-command* nil)
      (set! *practice-command-index* 0)
      (set! *practice-sleep-mode* nil)
      (status-mode-remove 'practice)
      (status-mode-remove 'practice-sleep)
      (practice-echo "Stopped"))))

(defun practice-send-empty ()
  "Timer callback: send empty string to refresh prompt."
  (if (and *practice-mode* *practice-sleep-mode*) (telnet-send "")))

(defun practice-enter-sleep ()
  "Enter sleep sub-mode when out of mana."
  (if (not *practice-sleep-mode*)
    (progn (set! *practice-sleep-mode* #t)
      (practice-echo "Sleeping (low mana)...")
      (practice-send "sleep")
      (status-mode-set 'practice-sleep "💤" 21)
      ;; Start timer for periodic prompt refresh
      (set! *practice-sleep-timer*
       (run-at-time *practice-sleep-interval* *practice-sleep-interval*
        practice-send-empty)))))

(defun practice-exit-sleep ()
  "Exit sleep sub-mode when mana is restored."
  (if *practice-sleep-mode*
    (progn
      ;; Cancel the timer
      (if *practice-sleep-timer*
        (progn (cancel-timer *practice-sleep-timer*)
          (set! *practice-sleep-timer* nil)))
      ;; Clear sleep mode
      (set! *practice-sleep-mode* nil)
      (status-mode-remove 'practice-sleep)
      (practice-echo "Waking up (mana restored)...")
      ;; Stand up and resume practicing
      (practice-send "stand")
      (practice-send (practice-current-command))
      (practice-advance-command))))

(defun practice-quit-on-hunger-thirst ()
  "Quit the game when hunger/thirst damage is detected (no one watching)."
  (practice-echo "Hunger/thirst damage detected - quitting (no one watching)")
  (practice-stop)
  (telnet-send "quit"))

;; ============================================================================
;; TELNET INPUT HOOK
;; ============================================================================
(defun practice-telnet-hook (text)
  "Handle telnet input for practice mode.
   Triggers on specific patterns for retry/sleep, prompt only for waking.
   Quits on hunger/thirst damage (indicates no one is watching)."
  (if *practice-mode*
    (let ((mana (practice-extract-mana text)))
      (cond
        ;; Check for hunger/thirst damage (quit - no one watching)
        ((regex-match? *practice-hunger-thirst-pattern* text)
         (practice-quit-on-hunger-thirst))
        ;; Check for mana exhaustion message (spell too costly)
        ((and (not *practice-sleep-mode*)
              (string-contains? text *practice-sleep-pattern*))
         (practice-enter-sleep))
        ;; Check if mana dropped below threshold
        ((and (not *practice-sleep-mode*) mana
              (< mana *practice-mana-threshold*))
         (practice-enter-sleep))
        ;; Check for retry patterns (spell failed, lost concentration, etc.)
        ((and (not *practice-sleep-mode*)
              (practice-matches-any-pattern? text *practice-retry-patterns*))
         (practice-send (practice-current-command)) (practice-advance-command))
        ;; In sleep mode: check prompt for mana restoration
        (*practice-sleep-mode*
         (if (and mana (>= mana 100)) (practice-exit-sleep)))))))

;; Register the telnet hook
(add-hook 'telnet-input-hook 'practice-telnet-hook)

;; ============================================================================
;; COMMAND HANDLER
;; ============================================================================
(defun practice-handler (args)
  (cond
    ((string=? args "stop") (practice-stop))
    ((string=? args "patterns") (practice-list-retry-patterns))
    ((string-prefix? "add " args)
     (practice-add-retry-pattern (substring args 4 (length args))))
    ((string-prefix? "remove " args)
     (practice-remove-retry-pattern (substring args 7 (length args))))
    ((> (length args) 0) (practice-start args))
    (#t
     (if *practice-mode*
       (practice-echo
        (concat "Currently practicing: " (join *practice-command* " | ")
         (if *practice-sleep-mode* " (sleeping)" "")))
       (practice-echo "Not practicing. Use /p <command> to start.")))))

(register-slash-command "/practice" practice-handler "Practice mode"
 :usage
 *practice-usage*
 :section
 *practice-features*)

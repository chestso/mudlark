;; Test Assertion Macros for telnet-lisp Test Suite
;; Provides assertion macros for test files: assert-equal, assert-true, assert-false,
;; assert-error, and assert-nil. All macros abort tests via (error ...) on failure.
;;
;; Also provides common mock functions that tests can override if needed.

;; ============================================================================
;; Common Mock Functions
;; ============================================================================
(defun termcap (capability &rest args)
  "Mock: return sensible defaults for terminal capabilities.
   Tests can override this with their own version if needed."
  (cond
    ((eq? capability 'fg-color) "")
    ((eq? capability 'bg-color) "")
    ((eq? capability 'reset) "")
    ((eq? capability 'unicode?) #t)
    ((eq? capability 'type) "xterm-256color")
    ((eq? capability 'encoding) "UTF-8")
    ((eq? capability 'color-level) 4)
    ((eq? capability 'cols) 80)
    ((eq? capability 'rows) 24)
    ((eq? capability 'truecolor?) #t)
    (#t "")))

;; App-level mocks for C builtins
(defvar *version* "1.0.0-test")
(defun terminal-echo (msg) nil)
(defun telnet-send (msg) nil)
(defvar *sent-inputs* '())
(defvar *sent-results* '())
(defun send-input (text)
  (set! *sent-inputs* (append *sent-inputs* (list text)))
  ;; Simulate event loop: process through hook pipeline synchronously
  (if (not (run-filter-hook 'user-input-hook text))
    nil
    (let ((result (run-transform-hook 'user-input-transform-hook text)))
      (cond
        ((and (string? result) (not (string=? result "")))
         (set! *sent-results* (append *sent-results* (list result))))
        ((pair? result)
         (set! *sent-results* (append *sent-results* result)))))))
(defun script-echo (title &rest args) nil)
(defun register-cli-handler (&rest args) nil)

;; Slash command mock system — provides a minimal dispatcher so tests
;; that call (run-user-input "/cmd args") work without loading init.lisp.
(define *mock-slash-commands* (make-hash-table))
(define *mock-slash-aliases* (make-hash-table))

(defun register-slash-command (name handler title &rest args)
  "Mock: register a slash command handler and optional aliases."
  (hash-set! *mock-slash-commands* name handler)
  (do ((rest args (cdr rest))) ((null? rest))
    (let ((item (car rest)))
      (when (eq? item :aliases) (set! rest (cdr rest))
        (when rest
          (do ((al (car rest) (cdr al))) ((null? al))
            (hash-set! *mock-slash-aliases* (car al) name)))))))

(defun mock-slash-dispatch (text)
  "Mock dispatcher: route /commands to registered handlers."
  (if (not (and (string? text) (> (length text) 0) (string-prefix? "/" text)))
    text
    (let ((space-pos (string-index text " ")))
      (let ((cmd (if space-pos (substring text 0 space-pos) text))
            (args (if space-pos
                    (substring text (+ space-pos 1) (length text)) "")))
        ;; Exact alias match
        (let ((target (hash-ref *mock-slash-aliases* cmd)))
          (if (not target)
            ;; Exact name or prefix match
            (if (hash-ref *mock-slash-commands* cmd)
              (set! target cmd)
              (do ((keys (hash-keys *mock-slash-commands*) (cdr keys)))
                ((or target (null? keys)))
                (when (string-prefix? cmd (car keys))
                  (set! target (car keys))))))
          (if target
            (let ((handler (hash-ref *mock-slash-commands* target)))
              (when handler (handler args))
              nil)
            text))))))

(defun run-at-time (delay repeat func &rest args) nil)
(defun cancel-timer (timer) nil)
(defun bloom-log (level category message) nil)
(defun set-status (&optional text) nil)
(defun status-mode-set (sym text prio) nil)
(defun status-mode-remove (sym) nil)
(defun strip-ansi (text) text)

;; ============================================================================
;; Hook System Mock (backed by *hooks* hash table, matches C implementation)
;; ============================================================================
(define *hooks* (make-hash-table))
(define *default-hooks* nil)

;; Check if fn already exists in a hook entry list (by eq? identity)
(defun hooks--has-fn? (lst fn)
  (cond
    ((null? lst) #f)
    ((eq? (car (car lst)) fn) #t)
    (#t (hooks--has-fn? (cdr lst) fn))))

;; Insert (fn . priority) into a sorted list, return new list
(defun hooks--insert-sorted (fn priority lst)
  (let ((entry (cons fn priority)))
    (cond
      ((null? lst) (list entry))
      ((< priority (cdr (car lst)))
       (cons entry lst))
      (#t (cons (car lst) (hooks--insert-sorted fn priority (cdr lst)))))))

;; Remove fn from hook entry list by eq? identity, return new list
(defun hooks--remove-fn (lst fn)
  (cond
    ((null? lst) nil)
    ((eq? (car (car lst)) fn) (cdr lst))
    (#t (cons (car lst) (hooks--remove-fn (cdr lst) fn)))))

(defun add-hook (hook fn-sym &rest rest-args)
  "Mock: add a hook handler (symbol) with optional priority."
  (let ((priority (if (null? rest-args) 50 (car rest-args)))
        (name (symbol->string hook)))
    (let ((hook-list (hash-ref *hooks* name)))
      (if (null? hook-list) (set! hook-list nil))
      (if (hooks--has-fn? hook-list fn-sym)
        nil
        (hash-set! *hooks* name
                   (hooks--insert-sorted fn-sym priority hook-list))))))

(defun remove-hook (hook fn-sym)
  "Mock: remove a hook handler (symbol)."
  (let ((name (symbol->string hook)))
    (let ((hook-list (hash-ref *hooks* name)))
      (if hook-list
        (hash-set! *hooks* name (hooks--remove-fn hook-list fn-sym))))))

(defun run-hook (hook &rest args)
  "Mock: run all functions registered on a hook (resolve symbols)."
  (let ((name (symbol->string hook)))
    (let ((hook-list (hash-ref *hooks* name)))
      (if hook-list
        (do ((remaining hook-list (cdr remaining)))
            ((null? remaining) nil)
          (apply (eval (car (car remaining))) args))))))

(defun run-transform-hook--map-list (fn lst)
  "Helper: call fn on each list element, collect non-nil results.
   If fn returns a list, splice its elements in."
  (if (null? lst)
    nil
    (let ((result (fn (car lst))))
      (cond
        ((null? result)
         (run-transform-hook--map-list fn (cdr lst)))
        ((pair? result)
         (append result (run-transform-hook--map-list fn (cdr lst))))
        (#t
         (cons result (run-transform-hook--map-list fn (cdr lst))))))))

(defun run-transform-hook--loop (entries val)
  "Helper: thread value through remaining hook entries (resolve symbols).
   When value is a list, call handler on each element individually."
  (if (null? entries)
    val
    (let ((fn (eval (car (car entries)))))
      (if (pair? val)
        (run-transform-hook--loop (cdr entries)
          (run-transform-hook--map-list fn val))
        (run-transform-hook--loop (cdr entries) (fn val))))))

(defun run-transform-hook (hook initial-value)
  "Mock: thread a value through all functions registered on a hook."
  (let ((name (symbol->string hook)))
    (let ((hook-list (hash-ref *hooks* name)))
      (if hook-list
        (run-transform-hook--loop hook-list initial-value)
        initial-value))))

(defun run-filter-hook (hook value)
  "Mock: call all handlers with value; return nil if any returned nil."
  (let ((name (symbol->string hook)))
    (let ((hook-list (hash-ref *hooks* name)))
      (if hook-list
        (let ((consumed nil))
          (do ((remaining hook-list (cdr remaining)))
              ((null? remaining)
               (if consumed nil value))
            (let ((result (apply (eval (car (car remaining))) (list value))))
              (if (null? result) (set! consumed #t)))))
        value))))

;; ============================================================================
;; Stdlib Mocks (from init.lisp)
;; ============================================================================
;; Word character set
(defvar *word-chars* "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-")
(defun word-char? (c) (string-index *word-chars* (char->string c)))

;; F-key binding system
(defvar *fkey-bindings* (make-hash-table))
(defun fkey-handler (n)
  (let ((fn (hash-ref *fkey-bindings* n)))
    (if fn (fn))))
(add-hook 'fkey-hook 'fkey-handler 50)
(add-hook 'user-input-hook 'mock-slash-dispatch 1)
(defun bind-fkey (n fn) (hash-set! *fkey-bindings* n fn))
(defun unbind-fkey (n) (hash-remove! *fkey-bindings* n))

;; ============================================================================
;; Session Mock System
;; ============================================================================
;; Simulates session isolation using hash tables as per-session variable stores.
;; Each session has its own hash table; telnet-session-switch changes the active one.

(define *mock-sessions* (make-hash-table))    ; "id" -> (name . vars-hash)
(define *mock-current-session* 1)
(define *mock-next-session-id* 2)

;; Helper: convert session id to hash key string
(defun mock-session-key (id) (format nil "~A" id))

;; Initialize default session
(hash-set! *mock-sessions* (mock-session-key 1) (cons "default" (make-hash-table)))

(defun telnet-session-create (name)
  "Mock: create a new session, returns its id."
  (let ((id *mock-next-session-id*))
    (set! *mock-next-session-id* (+ *mock-next-session-id* 1))
    (hash-set! *mock-sessions* (mock-session-key id)
               (cons name (make-hash-table)))
    id))

(defun telnet-session-list ()
  "Mock: return list of (id . name) pairs."
  (let ((result nil)
        (keys (hash-keys *mock-sessions*)))
    (do ((remaining keys (cdr remaining)))
        ((null? remaining) result)
      (let ((k (car remaining)))
        (let ((v (hash-ref *mock-sessions* k)))
          (set! result (cons (cons (string->number k) (car v)) result)))))))

(defun telnet-session-current ()
  "Mock: return current session id."
  *mock-current-session*)

(defun telnet-session-switch (id)
  "Mock: switch to session by id."
  (if (hash-ref *mock-sessions* (mock-session-key id))
    (progn (set! *mock-current-session* id) #t)
    (error "telnet-session-switch: no session with that id")))

(defun telnet-session-name (&rest args)
  "Mock: get session name. No args = current, one arg = by id."
  (let ((id (if (null? args) *mock-current-session* (car args))))
    (let ((entry (hash-ref *mock-sessions* (mock-session-key id))))
      (if entry (car entry) nil))))

(defun telnet-session-destroy (id)
  "Mock: destroy a session by id."
  (cond
    ((= id *mock-current-session*)
     (error "telnet-session-destroy: failed (not found or current session)"))
    ((hash-ref *mock-sessions* (mock-session-key id))
     (hash-remove! *mock-sessions* (mock-session-key id))
     #t)
    (#t (error "telnet-session-destroy: failed (not found or current session)"))))

;; Per-session variable helpers for testing isolation
(defun session-var-set (key value)
  "Set a variable in the current mock session's variable store."
  (let ((entry (hash-ref *mock-sessions* (mock-session-key *mock-current-session*))))
    (hash-set! (cdr entry) key value)))

(defun session-var-get (key)
  "Get a variable from the current mock session's variable store."
  (let ((entry (hash-ref *mock-sessions* (mock-session-key *mock-current-session*))))
    (hash-ref (cdr entry) key)))
;; ============================================================================
;; Common Test Utilities
;; ============================================================================
(defun member? (item lst)
  "Return #t if item is in lst (by equal?)."
  (cond ((null? lst) #f)
        ((equal? (car lst) item) #t)
        (#t (member? item (cdr lst)))))

(defun reset-completion-store (capacity)
  "Reset the completion word store to empty with given capacity.
   Only works in tests that load init.lisp."
  (set! *completion-trie* (cons nil (make-hash-table)))
  (set! *completion-words* (make-hash-table))
  (set! *completion-seq* 0)
  (set! *completion-word-store-size* capacity)
  (set! *completion-word-order* (make-vector capacity nil))
  (set! *completion-word-order-index* 0)
  (set! *completion-word-count* 0))

;; ============================================================================
;; Assertion Macros
;; ============================================================================
;; Assert that actual equals expected (handles numbers and structural equality)
;; Usage: (assert-equal actual expected "description")
;; Returns: nil on success, aborts test with error on failure
(defmacro assert-equal (actual expected message)
  `(let ((actual-val ,actual)
         (expected-val ,expected))
     ;; Use = for numbers, equal? for everything else
     (let ((values-equal
            (if (and (number? actual-val) (number? expected-val))
              (= actual-val expected-val)
              (equal? actual-val expected-val))))
       (if values-equal
         nil ; Success: silent
         (error
          (format nil "Assertion failed: ~A~%  Expected: ~S~%  Actual:   ~S"
           ,message expected-val actual-val))))))

;; Assert that condition evaluates to truthy value (anything except nil/#f)
;; Usage: (assert-true condition "description")
;; Returns: nil on success, aborts test with error on failure
(defmacro assert-true (condition message)
  `(let ((result ,condition))
     (if result
       nil ; Success: silent
       (error
        (format nil "Assertion failed: ~A (expected truthy, got: ~S)" ,message
         result)))))

;; Assert that condition evaluates to falsy value (nil or #f)
;; Usage: (assert-false condition "description")
;; Returns: nil on success, aborts test with error on failure
(defmacro assert-false (condition message)
  `(let ((result ,condition))
     (if result
       (error
        (format nil "Assertion failed: ~A (expected falsy, got: ~S)" ,message
         result))
       nil))) ; Success: silent

;; Assert that expression throws an error
;; Usage: (assert-error expr "description")
;; Returns: nil on success (if error thrown), aborts test if expr succeeds
(defmacro assert-error (expr message)
  `(condition-case err
     (progn ,expr
       (error
        (format nil "Assertion failed: ~A (expected error but succeeded)"
         ,message)))
     (error nil))) ; Success: error was thrown

;; Assert that expression evaluates to nil explicitly
;; Usage: (assert-nil expr "description")
;; Returns: nil on success, aborts test with error on failure
(defmacro assert-nil (expr message)
  `(let ((result ,expr))
     (if (null? result)
       nil ; Success
       (error
        (format nil "Assertion failed: ~A (expected nil, got: ~S)" ,message
         result)))))

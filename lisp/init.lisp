;; Bootstrap Lisp file for mudlark
;; Loaded into base_env on startup after the TUI is initialized.
;; All variables defined here can be overridden in your custom Lisp configuration file.
;; ============================================================================
;; WORD STORE CONFIGURATION
;; ============================================================================
(defvar *completion-word-store-size* 50000
  "Maximum number of words to store for completions.")

(defvar *completion-max-results* 64
  "Maximum number of completion candidates to return per prefix.")

;; Initialize trie root — each node is (leaf-list . children-hash).
;; Leaf data is in car: nil if not terminal, else a list of (word seq slot) entries.
;; Multiple case variants share the same trie path (lowercased).
(define *completion-trie* (cons nil (make-hash-table)))

;; Flat hash for O(1) duplicate detection: original-word -> (word seq slot trie-node)
;; The trie-node reference allows O(1) leaf updates on duplicates.
(define *completion-words* (make-hash-table))

;; Recency counter (monotonically increasing)
(define *completion-seq* 0)

;; Initialize word order (vector for FIFO bounded storage)
(define *completion-word-order* (make-vector *completion-word-store-size* nil))

;; Current position in the order vector (circular buffer index)
(define *completion-word-order-index* 0)

;; Number of words currently stored (may be less than vector capacity)
(define *completion-word-count* 0)

;; ============================================================================
;; TELNET I/O LOGGING CONFIGURATION
;; ============================================================================
(defvar *enable-telnet-logging* #t
  "Enable/disable telnet I/O logging (both send and receive).")

(defvar *telnet-log-directory* "~/telnet-logs"
  "Directory for telnet log files (supports ~/ expansion).")

;; ============================================================================
;; TCP KEEPALIVE CONFIGURATION
;; ============================================================================
(defvar *tcp-keepalive-enabled* #t
  "Enable TCP keepalive probes on telnet connections.")

(defvar *tcp-keepalive-time* 60
  "Seconds of idle time before sending the first keepalive probe.")

(defvar *tcp-keepalive-interval* 10
  "Seconds between keepalive probes after the first probe.")

;; ============================================================================
;; CONNECTION TIMEOUT CONFIGURATION
;; ============================================================================
(defvar *connect-timeout* 2
  "Seconds to wait for each connection attempt before retrying.")

(defvar *connect-max-retries* 5
  "Maximum number of connection retries after the initial attempt.")

;; ============================================================================
;; INPUT CONFIGURATION
;; ============================================================================
(defvar *input-history-size* 1000
  "Maximum number of input history entries to keep.")

(defvar *prompt* "❯ " "Input prompt string.")

;; ============================================================================
;; COLOR CONFIGURATION
;; ============================================================================
;; UI colors — each is an (R G B) list. Override in your config to customize.
(defvar *color-user-input* '(255 215 0)
  "Color for echoed user input. RGB list.")

(defvar *color-divider-connected* '(37 160 101)
  "Divider color when connected. RGB list.")

(defvar *color-divider-disconnected* '(88 88 88)
  "Divider color when disconnected. RGB list.")

(defvar *color-log-debug* '(128 128 128)
  "Color for debug log messages. RGB list.")

(defvar *color-log-info* '(128 128 128)
  "Color for info log messages. RGB list.")

(defvar *color-log-warn* '(255 200 0)
  "Color for warning log messages. RGB list.")

(defvar *color-log-error* '(255 80 80)
  "Color for error log messages. RGB list.")

(defvar *color-script-header* '(255 177 182)
  "Color for script-echo header text. RGB list.")

(defvar *color-script-desc* '(157 225 241)
  "Color for script-echo description text. RGB list.")

(defvar *color-script-section* '(189 147 249)
  "Color for script-echo section titles. RGB list.")

(defvar *color-script-detail* '(100 100 156)
  "Color for script-echo detail text. RGB list.")

(defvar *color-script-mdash* '(98 98 98)
  "Color for script-echo mdash separator. RGB list.")

(defun color->fg (rgb)
  "Convert an RGB list to a foreground ANSI escape sequence."
  (termcap 'fg-color (car rgb) (car (cdr rgb)) (car (cdr (cdr rgb)))))

;; ============================================================================
;; WORD CHARACTER SET (whitelist)
;; ============================================================================
(defvar *word-chars*
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
  "Characters that form words for completion and word movement.")

(defun word-char? (c)
  "Return #t if character is part of a word."
  (string-index *word-chars* (char->string c)))

;; ============================================================================
;; TRIE FUNCTIONS
;; ============================================================================
;; Each trie node is (leaf-list . children-hash):
;;   car = nil if not terminal, else list of (word seq slot) entries
;;   cdr = hash table mapping single-char strings to child nodes
;; Multiple case variants share one trie path; each gets its own entry in the list.
(defun trie-make-node ()
  "Create a new trie node with no leaf and no children."
  (cons nil (make-hash-table)))

(defun trie-insert! (root word leaf-data)
  "Insert word into trie, adding leaf-data to the terminal node's entry list.
   Returns the terminal node."
  (let ((node root)
        (len (length word)))
    (do ((i 0 (+ i 1))) ((>= i len))
      (let* ((ch (substring word i (+ i 1)))
             (children (cdr node))
             (child (hash-ref children ch)))
        (when (null? child) (set! child (trie-make-node))
          (hash-set! children ch child))
        (set! node child)))
    (set-car! node (cons leaf-data (car node)))
    node))

(defun trie-leaf-remove (leaf-list word)
  "Remove the entry with matching word from a leaf list."
  (cond
    ((null? leaf-list) nil)
    ((string=? (car (car leaf-list)) word) (cdr leaf-list))
    (#t (cons (car leaf-list) (trie-leaf-remove (cdr leaf-list) word)))))

(defun trie-remove-entry! (root trie-key word)
  "Remove a specific entry (by original word) from the trie node at trie-key.
   Prunes empty nodes bottom-up. Returns #t if removed."
  (let ((len (length trie-key)))
    (if (= len 0)
      #f
      ;; Build path of (node . char-key) pairs for cleanup
      (let ((path (list (cons root (substring trie-key 0 1))))
            (node root)
            (found #t))
        ;; Walk to terminal node
        (do ((i 0 (+ i 1))) ((or (>= i len) (not found)))
          (let ((child (hash-ref (cdr node) (substring trie-key i (+ i 1)))))
            (if (null? child)
              (set! found #f)
              (progn
                (when (< (+ i 1) len)
                  (set! path
                   (cons (cons child (substring trie-key (+ i 1) (+ i 2))) path)))
                (set! node child)))))
        (if (not found)
          #f
          (if (null? (car node))
            #f
            (let ((new-leaf (trie-leaf-remove (car node) word)))
              (set-car! node new-leaf)
              ;; Prune empty nodes bottom-up (only if leaf list is now empty)
              (when (null? new-leaf)
                (do ((remaining path (cdr remaining))) ((null? remaining))
                  (let* ((pair (car remaining))
                         (parent (car pair))
                         (key (cdr pair))
                         (child (hash-ref (cdr parent) key)))
                    (when
                      (and child (null? (car child))
                           (= (length (hash-keys (cdr child))) 0))
                      (hash-remove! (cdr parent) key)))))
              #t)))))))

(defun trie-walk-to (root prefix)
  "Walk trie following prefix characters. Returns node or nil."
  (let ((node root)
        (len (length prefix))
        (found #t))
    (do ((i 0 (+ i 1))) ((or (>= i len) (not found)))
      (let ((child (hash-ref (cdr node) (substring prefix i (+ i 1)))))
        (if (null? child) (set! found #f) (set! node child))))
    (if found node nil)))

(defun trie-collect (node)
  "DFS collect all leaf entries under node (flattening leaf lists)."
  (let ((acc '()))
    (let ((leaf (car node))) (when leaf (set! acc (append leaf acc))))
    (let ((keys (hash-keys (cdr node))))
      (do ((remaining keys (cdr remaining))) ((null? remaining) acc)
        (set! acc
         (append (trie-collect (hash-ref (cdr node) (car remaining))) acc))))))

(defun merge-sort-by-seq-desc (lst)
  "Merge sort list of entries by seq number (index 1) descending."
  (if (or (null? lst) (null? (cdr lst)))
    lst
    (let ((mid (quotient (length lst) 2))
          (left '())
          (right '()))
      ;; Split into two halves
      (do ((remaining lst (cdr remaining)) (i 0 (+ i 1))) ((null? remaining))
        (if (< i mid)
          (set! left (cons (car remaining) left))
          (set! right (cons (car remaining) right))))
      (set! left (reverse left))
      (set! right (reverse right))
      ;; Recursively sort and merge
      (let ((sl (merge-sort-by-seq-desc left))
            (sr (merge-sort-by-seq-desc right))
            (result '()))
        ;; Merge descending
        (do () ((and (null? sl) (null? sr)) (reverse result))
          (cond
            ((null? sl) (set! result (cons (car sr) result)) (set! sr (cdr sr)))
            ((null? sr) (set! result (cons (car sl) result)) (set! sl (cdr sl)))
            ((> (list-ref (car sl) 1) (list-ref (car sr) 1))
             (set! result (cons (car sl) result)) (set! sl (cdr sl)))
            (#t (set! result (cons (car sr) result)) (set! sr (cdr sr)))))))))

(defun take-at-most (n lst)
  "Return first N elements of list, or all if fewer than N."
  (let ((acc '()))
    (do ((remaining lst (cdr remaining)) (i 0 (+ i 1)))
      ((or (null? remaining) (>= i n)) (reverse acc))
      (set! acc (cons (car remaining) acc)))))

;; ============================================================================
;; WORD STORE INSERT/QUERY
;; ============================================================================
(defun add-word-to-store (word)
  "Add a word to the completion store with FIFO eviction.
   Each case variant is stored separately; the trie path is lowercased."
  (if (not (and (string? word) (>= (length word) 3)))
    0
    (let* ((lower (string-downcase word))
           (vec *completion-word-order*)
           (vec-size (length vec))
           (existing (hash-ref *completion-words* word)))
      ;; If duplicate (same case), clear its old buffer slot
      (when existing (vector-set! vec (list-ref existing 2) nil))
      ;; Wrap index
      (when (>= *completion-word-order-index* vec-size)
        (set! *completion-word-order-index* 0))
      (let* ((slot *completion-word-order-index*)
             (old-entry (vector-ref vec slot)))
        ;; Evict old word: remove from hash and its entry from trie leaf list
        (when (string? old-entry) (hash-remove! *completion-words* old-entry)
          (trie-remove-entry! *completion-trie* (string-downcase old-entry)
           old-entry))
        ;; Bump seq
        (set! *completion-seq* (+ *completion-seq* 1))
        (let ((leaf (list word *completion-seq* slot)))
          (if existing
            ;; DUPLICATE: update entry in cached trie node's leaf list
            (let ((trie-node (list-ref existing 3)))
              (set-car! trie-node
               (cons leaf (trie-leaf-remove (car trie-node) word)))
              (hash-set! *completion-words* word
               (list word *completion-seq* slot trie-node)))
            ;; NEW WORD: insert into trie (appends to leaf list at terminal node)
            (let ((trie-node (trie-insert! *completion-trie* lower leaf)))
              (hash-set! *completion-words* word
               (list word *completion-seq* slot trie-node)))))
        ;; Store original word in buffer slot (not lowercase)
        (vector-set! vec slot word)
        ;; Track word count
        (if (null? existing)
          (when (not (string? old-entry))
            (set! *completion-word-count* (+ *completion-word-count* 1)))
          (when (string? old-entry)
            (set! *completion-word-count* (- *completion-word-count* 1))))
        ;; Advance index
        (set! *completion-word-order-index* (+ *completion-word-order-index* 1))
        (when (>= *completion-word-order-index* vec-size)
          (set! *completion-word-order-index* 0))
        1))))

(defun get-completions-from-store (prefix)
  "Retrieve words from store matching a prefix (case-insensitive).
   Results with a case-exact prefix match are prioritized first,
   then remaining results. Both groups sorted by recency."
  (if (not (and (string? prefix) (> (length prefix) 0)))
    '()
    (let ((node (trie-walk-to *completion-trie* (string-downcase prefix))))
      (if (null? node)
        '()
        (let* ((entries (trie-collect node))
               (sorted (merge-sort-by-seq-desc entries))
               (plen (length prefix))
               (matched '())
               (unmatched '()))
          ;; Partition by case-exact prefix match
          (do ((remaining sorted (cdr remaining))) ((null? remaining))
            (let ((word (car (car remaining))))
              (if
                (and (>= (length word) plen)
                     (string=? (substring word 0 plen) prefix))
                (set! matched (cons (car remaining) matched))
                (set! unmatched (cons (car remaining) unmatched)))))
          (let ((result (append (reverse matched) (reverse unmatched))))
            (map car (take-at-most *completion-max-results* result))))))))

(defvar *collect-words-max-length* 65536
  "Maximum text length for word collection. Texts longer than this are truncated.")

(defun collect-words-from-text (text)
  "Extract words from text and add them to completion store.
   Scans character-by-character using string ports for O(1) access."
  (if (not (string? text))
    ()
    (let* ((input
            (if (> (length text) *collect-words-max-length*)
              (substring text 0 *collect-words-max-length*)
              text))
           (port (open-input-string input))
           (src (port-source port))
           (word-start -1))
      (do () ((port-eof? port))
        (let ((c (port-read-char port))
              (pos (- (port-position port) 1)))
          (if (word-char? c)
            (when (< word-start 0) (set! word-start pos))
            (when (>= word-start 0)
              (when (>= (- pos word-start) 3)
                (add-word-to-store (substring src word-start pos)))
              (set! word-start -1)))))
      ;; Flush trailing word
      (when (>= word-start 0)
        (let ((end (port-position port)))
          (when (>= (- end word-start) 3)
            (add-word-to-store (substring src word-start end))))))))

;; ============================================================================
;; HOOKS
;; ============================================================================
;; Hook dispatch uses a per-session *hooks* hash table (key = hook name,
;; value = sorted list of (fn . priority) pairs). add-hook, remove-hook,
;; run-hook, run-transform-hook are C builtins that operate on this table.
;; These wrappers are called from C via lisp_x_call_* functions.
;; -- Wrappers called from C --
(defun telnet-input-hook (text)
  "Process telnet server output through registered hooks."
  (run-hook 'telnet-input-hook text)
  nil)

(defun telnet-input-transform-hook (text)
  "Transform telnet server output before displaying."
  (run-transform-hook 'telnet-input-transform-hook text))

(defun user-input-hook (text)
  "Process user input through registered filter hooks.
   Any handler returning nil consumes the input."
  (run-filter-hook 'user-input-hook text))

(defun user-input-transform-hook (text)
  "Transform user input before sending to telnet server."
  (run-transform-hook 'user-input-transform-hook text))

(defun completion-hook (text)
  "Provide tab completion candidates from word store."
  (if (and (string? text) (> (length text) 0))
    (get-completions-from-store text)
    '()))

;; -- Default handlers --
(defun default-word-collector (text)
  "Default telnet-input-hook handler that collects words for tab completion."
  (collect-words-from-text text))

(add-hook 'telnet-input-hook 'default-word-collector)

;; ============================================================================
;; TIMER SYSTEM
;; ============================================================================
(defvar *timer-list* '()
  "List of active timers (sorted by fire-time ascending).")

(defvar *timer-next-id* 1 "Next timer ID to assign.")

(defvar *timer-next-fire-ms* -1
  "Cached fire-time of the earliest timer, or -1 if none. Read by C for select() timeout.")

(defun timer--update-cache ()
  "Set *timer-next-fire-ms* from the head of the sorted timer list."
  (set! *timer-next-fire-ms*
   (if (null? *timer-list*) -1 (list-ref (car *timer-list*) 1))))

(defun timer--insert-sorted (timer lst)
  "Insert TIMER into LST maintaining ascending fire-time order."
  (if (null? lst)
    (list timer)
    (if (<= (list-ref timer 1) (list-ref (car lst) 1))
      (cons timer lst)
      (cons (car lst) (timer--insert-sorted timer (cdr lst))))))

(defun run-at-time (time repeat function &rest args)
  "Schedule FUNCTION to run after TIME seconds.
If REPEAT is non-nil, re-run every REPEAT seconds.
Returns a timer object that can be passed to cancel-timer.

Example — send a command every 10 seconds:
  (run-at-time 0 10 (lambda () (telnet-send \"look\")))"
  (let* ((delay-ms (* time 1000))
         (repeat-ms (if repeat (* repeat 1000) 0))
         (fire-time (+ (current-time-ms) delay-ms))
         (id *timer-next-id*)
         (timer (list id fire-time repeat-ms function args)))
    (set! *timer-next-id* (+ *timer-next-id* 1))
    (set! *timer-list* (timer--insert-sorted timer *timer-list*))
    (timer--update-cache)
    (when (bound? 'wake-event-loop) (wake-event-loop))
    timer))

(defun cancel-timer (timer)
  "Cancel TIMER."
  (let ((found #f))
    (set! *timer-list*
     (filter (lambda (t) (if (eq? t timer) (progn (set! found #t) #f) #t))
      *timer-list*))
    (when found (timer--update-cache)
      (when (bound? 'wake-event-loop) (wake-event-loop)))
    found))

(defun list-timers () "Return list of active timers." *timer-list*)

(defun run-timers ()
  "Run all due timers. Called automatically by main loop."
  (when (not (null? *timer-list*))
    (let ((now (current-time-ms))
          (to-process *timer-list*)
          (repeaters '()))
      ;; Detach list so callbacks that schedule timers don't interfere
      (set! *timer-list* '())
      ;; Walk sorted list, fire due timers, collect repeaters
      (do ((remaining to-process (cdr remaining)))
        ((or (null? remaining) (> (list-ref (car remaining) 1) now))
         ;; Non-due tail is already sorted — set as base
         (when (and remaining (not (null? remaining)))
           (set! *timer-list* remaining)))
        (let* ((timer (car remaining))
               (fire-time (list-ref timer 1))
               (repeat-ms (list-ref timer 2))
               (callback (list-ref timer 3))
               (args (list-ref timer 4)))
          (apply callback args)
          (when (> repeat-ms 0)
            ;; Drift fix: advance from scheduled time, not current time
            (set-car! (cdr timer) (+ fire-time repeat-ms))
            (set! repeaters (cons timer repeaters)))))
      ;; Merge any callbacks-added timers with survivors, then insert repeaters
      (do ((r repeaters (cdr r))) ((null? r))
        (set! *timer-list* (timer--insert-sorted (car r) *timer-list*)))
      (timer--update-cache))))

;; ============================================================================
;; UTILITY FUNCTIONS
;; ============================================================================
(defun build-indent (level)
  (let ((result ""))
    (do ((i 0 (+ i 1))) ((>= i level) result)
      (set! result (concat result "  ")))))

(defun obj-to-string (obj)
  "Convert an object to its string representation."
  (cond
    ((symbol? obj) (symbol->string obj))
    ((string? obj) obj)
    ((eq? obj #t) "#t")
    ((eq? obj #f) "#f")
    (#t (format nil "~A" obj))))

;; ============================================================================
;; COMPLETION DIAGNOSTICS
;; ============================================================================
(defun completion-debug-info ()
  "Print completion word store diagnostics."
  (let* ((vec *completion-word-order*)
         (vec-size (length vec))
         (idx *completion-word-order-index*))
    (terminal-echo
     (concat "\r\nCompletion store: " (number->string *completion-word-count*)
      " words (hash+trie)\r\n" "Circular buffer size: "
      (number->string vec-size) "\r\n" "Buffer index: " (number->string idx)
      "\r\n"))))

;; ============================================================================
;; SCRIPT STARTUP BANNERS
;; ============================================================================
;; Bubbletea-inspired soft pastel color palette
(defun script-echo (title &rest args)
  "Print a styled script startup banner with optional description and sections.

Each keyword takes exactly one string argument. Use newlines for multiline content.

Usage:
  (script-echo \"Title\")
  (script-echo \"Title\" :desc \"short description\")
  (script-echo \"Title\"
    :desc \"description\"
    :section \"Usage\\ncmd1\\ncmd2\"
    :section \"Features\\nfeature1\\nfeature2\")

Colors: header=pale pink, desc=pale cyan, section=lavender, details=slate blue"
  (let ((c-header (color->fg *color-script-header*))
        (c-desc (color->fg *color-script-desc*))
        (c-section (color->fg *color-script-section*))
        (c-detail (color->fg *color-script-detail*))
        (c-mdash (color->fg *color-script-mdash*))
        (reset (termcap 'reset))
        (desc nil)
        (sections nil))
    ;; Parse args: each keyword takes exactly one string argument
    (do ((rest args (cdr rest))) ((null? rest))
      (let ((item (car rest)))
        (cond
          ((eq? item :desc) (set! rest (cdr rest))
           (when rest (set! desc (car rest))))
          ((eq? item :section) (set! rest (cdr rest))
           (when rest (set! sections (cons (car rest) sections)))))))
    (set! sections (reverse sections))
    ;; Output header line
    (terminal-echo (concat c-header title reset))
    (when desc (terminal-echo (concat c-mdash " — " reset c-desc desc reset)))
    (terminal-echo "\r\n")
    ;; Output sections
    (do ((slist sections (cdr slist))) ((null? slist))
      (let* ((text (car slist))
             (lines (string-split text "\n")))
        (if (null? (cdr lines))
          ;; Single line section: render as detail
          (terminal-echo (concat "  " c-detail (car lines) reset "\r\n"))
          ;; Multi-line: first line is title, rest are details
          (progn
            (terminal-echo (concat "  " c-section (car lines) reset "\r\n"))
            (do ((dlist (cdr lines) (cdr dlist))) ((null? dlist))
              (terminal-echo (concat "    " c-detail (car dlist) reset "\r\n")))))))))

;; ============================================================================
;; SLASH COMMAND SYSTEM
;; ============================================================================
;; Central registry and dispatcher for /commands. Scripts register via
;; register-slash-command; a single user-input-hook handler dispatches
;; by prefix match, with /help and /doc built in.
(define *slash-commands* (make-hash-table))

(define *slash-command-aliases* (make-hash-table))

(defun slash-command--insert-sorted (entry sorted)
  "Insert entry into sorted list by name (car), ascending."
  (cond
    ((null? sorted) (list entry))
    ((string<? (car entry) (car (car sorted))) (cons entry sorted))
    (#t (cons (car sorted) (slash-command--insert-sorted entry (cdr sorted))))))

(defun register-slash-command (name handler title &rest args)
  "Register a slash command with handler and optional documentation.
   Keywords: :desc, :aliases, :usage, :commands, :config, :section"
  (let ((desc nil)
        (aliases nil)
        (usage nil)
        (commands nil)
        (config nil)
        (custom-sections nil))
    ;; Parse keyword args
    (do ((rest args (cdr rest))) ((null? rest))
      (let ((item (car rest)))
        (cond
          ((eq? item :desc) (set! rest (cdr rest))
           (when rest (set! desc (car rest))))
          ((eq? item :aliases) (set! rest (cdr rest))
           (when rest (set! aliases (car rest))))
          ((eq? item :usage) (set! rest (cdr rest))
           (when rest (set! usage (car rest))))
          ((eq? item :commands) (set! rest (cdr rest))
           (when rest (set! commands (car rest))))
          ((eq? item :config) (set! rest (cdr rest))
           (when rest (set! config (car rest))))
          ((eq? item :section) (set! rest (cdr rest))
           (when rest (set! custom-sections (cons (car rest) custom-sections)))))))
    (set! custom-sections (reverse custom-sections))
    ;; Build ordered sections: Usage, Commands, Config, custom
    (let ((sections '()))
      (when usage (set! sections (cons (concat "Usage\n" usage) sections)))
      (when commands
        (set! sections (cons (concat "Commands\n" commands) sections)))
      (when config (set! sections (cons (concat "Config\n" config) sections)))
      (do ((cs custom-sections (cdr cs))) ((null? cs))
        (set! sections (cons (car cs) sections)))
      (set! sections (reverse sections))
      ;; Store entry: (handler title desc sections aliases)
      (hash-set! *slash-commands* name
       (list handler title desc sections aliases))
      ;; Register aliases
      (when aliases
        (do ((al aliases (cdr al))) ((null? al))
          (hash-set! *slash-command-aliases* (car al) name)))
      ;; Display startup banner via script-echo
      (let ((banner-args (list title)))
        (when desc (set! banner-args (append banner-args (list :desc desc))))
        (do ((sl sections (cdr sl))) ((null? sl))
          (set! banner-args (append banner-args (list :section (car sl)))))
        (apply script-echo banner-args)))))

(defun slash-command-prefix-matches (cmd)
  "Return list of registered command names that cmd is a prefix of."
  (let ((matches nil))
    (do ((keys (hash-keys *slash-commands*) (cdr keys))) ((null? keys))
      (when (string-prefix? cmd (car keys))
        (set! matches (cons (car keys) matches))))
    matches))

(defun slash-command-lookup (cmd)
  "Resolve a command string to its canonical name.
   Returns canonical name (string), list of matches (ambiguous), or nil."
  (let ((alias-target (hash-ref *slash-command-aliases* cmd)))
    (if alias-target
      alias-target
      (if (hash-ref *slash-commands* cmd)
        cmd
        (let ((matches (slash-command-prefix-matches cmd)))
          (cond
            ((null? matches) nil)
            ((null? (cdr matches)) (car matches))
            (#t matches)))))))

(defun slash-command-show-help (name)
  "Display detailed help for a slash command via script-echo."
  (let ((entry (hash-ref *slash-commands* name)))
    (when entry
      (let ((title (list-ref entry 1))
            (desc (list-ref entry 2))
            (sections (list-ref entry 3)))
        (let ((banner-args (list title)))
          (when desc (set! banner-args (append banner-args (list :desc desc))))
          (do ((sl sections (cdr sl))) ((null? sl))
            (set! banner-args (append banner-args (list :section (car sl)))))
          (apply script-echo banner-args))))))

(defun slash-command-list-all ()
  "Display a summary of all registered slash commands."
  (let ((c-header (color->fg *color-script-header*))
        (c-desc (color->fg *color-script-desc*))
        (c-detail (color->fg *color-script-detail*))
        (reset (termcap 'reset))
        (entries nil))
    ;; Collect (name display-text aliases) triples
    (do ((keys (hash-keys *slash-commands*) (cdr keys))) ((null? keys))
      (let* ((name (car keys))
             (entry (hash-ref *slash-commands* name))
             (title (list-ref entry 1))
             (desc (list-ref entry 2))
             (aliases (list-ref entry 4)))
        (set! entries (cons (list name (if desc desc title) aliases) entries))))
    ;; Sort alphabetically by name
    (let ((sorted nil))
      (do ((remaining entries (cdr remaining))) ((null? remaining))
        (set! sorted (slash-command--insert-sorted (car remaining) sorted)))
      ;; Output
      (terminal-echo (concat "\r\n" c-header "Slash Commands" reset "\r\n"))
      (do ((remaining sorted (cdr remaining))) ((null? remaining))
        (let* ((e (car remaining))
               (name (car e))
               (display-desc (cadr e))
               (aliases (caddr e))
               (alias-str
                (if aliases (concat " (" (string-join aliases ", ") ")") ""))
               (label (concat name alias-str))
               (pad (- 24 (length label))))
          (terminal-echo
           (concat "  " c-desc label reset
            (repeat-string " " (if (< pad 1) 1 pad)) c-detail display-desc
            reset "\r\n"))))
      (terminal-echo "\r\n"))))

(defun slash-command-show-ambiguous (cmd matches)
  "Display ambiguous command error with list of matches."
  (terminal-echo
   (concat "\r\nAmbiguous command: " cmd " matches " (string-join matches ", ")
    "\r\n")))

(defun slash-help-handler (args)
  "Handler for /help and /doc commands."
  (if (string=? args "")
    (slash-command-list-all)
    (let ((cmd (if (string-prefix? "/" args) args (concat "/" args))))
      (let ((result (slash-command-lookup cmd)))
        (cond
          ((null? result)
           (terminal-echo (concat "\r\nUnknown command: " cmd "\r\n")))
          ((pair? result) (slash-command-show-ambiguous cmd result))
          (#t (slash-command-show-help result)))))))

(defun slash-command-hook (text)
  "Central dispatcher for slash commands.
   Returns nil to consume input, text to pass through."
  (if (not (and (string? text) (> (length text) 0) (string-prefix? "/" text)))
    text
    (let ((space-pos (string-index text " ")))
      (let ((cmd (if space-pos (substring text 0 space-pos) text))
            (args
             (if space-pos (substring text (+ space-pos 1) (length text)) "")))
        (let ((result (slash-command-lookup cmd)))
          (cond
            ((null? result) text)
            ((pair? result) (slash-command-show-ambiguous cmd result) nil)
            (#t
             (let ((entry (hash-ref *slash-commands* result)))
               (if (string=? args "help")
                 (progn (slash-command-show-help result) nil)
                 (progn ((car entry) args) nil))))))))))

;; Register central dispatcher at highest priority
(add-hook 'user-input-hook 'slash-command-hook 1)

;; ============================================================================
;; STATUS MODE REGISTRY
;; ============================================================================
;; Composes a right-aligned title into the top divider above the textinput
;; via the C builtin `set-status`. Mode entries are (symbol text priority).
(defvar *status-mode-registry* '()
  "Registry of active status modes. Each entry is (symbol text priority).")

(defun status--insert-sorted (entry lst)
  "Insert entry into list sorted by priority (descending)."
  (cond
    ((null? lst) (list entry))
    ((> (list-ref entry 2) (list-ref (car lst) 2)) (cons entry lst))
    (#t (cons (car lst) (status--insert-sorted entry (cdr lst))))))

(defun status--compose-modes ()
  "Compose all modes into a single string and update the divider status."
  (if (null? *status-mode-registry*)
    (set-status)
    (let ((texts (map (lambda (e) (list-ref e 1)) *status-mode-registry*)))
      (set-status (string-join texts "")))))

(defun status-mode-set (mode-symbol text priority)
  "Add or update a status mode indicator (embedded in the top divider).

   Arguments:
   - mode-symbol: A symbol identifying this mode (for later removal)
   - text: The display text shown in the divider
   - priority: Integer priority (higher = leftmost)

   Multiple modes are composed together with \" · \" separator,
   sorted by priority (highest first).

   Example:
     (status-mode-set 'recording \"REC\" 100)
     (status-mode-set 'practice \"Practice\" 50)"
  ;; Remove existing entry with same symbol
  (set! *status-mode-registry*
   (filter (lambda (e) (not (eq? (car e) mode-symbol)))
    *status-mode-registry*))
  ;; Insert new entry in sorted position
  (set! *status-mode-registry*
   (status--insert-sorted (list mode-symbol text priority)
    *status-mode-registry*))
  (status--compose-modes)
  nil)

(defun status-mode-remove (mode-symbol)
  "Remove a status mode indicator from the top divider.

   The mode is identified by the symbol used when it was set.

   Example:
     (status-mode-remove 'recording)"
  (set! *status-mode-registry*
   (filter (lambda (e) (not (eq? (car e) mode-symbol)))
    *status-mode-registry*))
  (status--compose-modes)
  nil)

;; ============================================================================
;; F-KEY BINDING SYSTEM
;; ============================================================================
;; Generic system for binding F1–F12 to Lisp functions.
;; C intercepts F-key presses and calls (run-hook 'fkey-hook N).
(defvar *fkey-bindings* (make-hash-table)
  "Hash table mapping F-key number (1-12) to function.")

(defun fkey-handler (n)
  "Dispatch F-key press to bound function, if any."
  (let ((fn (hash-ref *fkey-bindings* n))) (if fn (fn))))

(add-hook 'fkey-hook 'fkey-handler 50)

(defun bind-fkey (n fn)
  "Bind F-key N (1-12) to function FN."
  (hash-set! *fkey-bindings* n fn))

(defun unbind-fkey (n)
  "Unbind F-key N (1-12)."
  (hash-remove! *fkey-bindings* n))

;; ============================================================================
;; DISPLAY UTILITY FUNCTIONS
;; ============================================================================
(defun visual-length (str)
  "Calculate display length of string, excluding ANSI escape codes."
  (if (not (string? str))
    0
    (let ((ansi-pattern "\\033\\[[0-9;]*m"))
      (length (regex-replace-all ansi-pattern str "")))))

(defun pad-string (str width)
  "Pad string to specified width with trailing spaces."
  (if (not (string? str))
    ""
    (let ((visual-len (visual-length str)))
      (let ((padding-needed (- width visual-len)))
        (if (<= padding-needed 0)
          str
          (let ((result str))
            (do ((i 0 (+ i 1))) ((>= i padding-needed) result)
              (set! result (concat result " ")))))))))

(defun repeat-string (str count)
  "Repeat a string N times."
  (if (<= count 0)
    ""
    (let ((result ""))
      (do ((i 0 (+ i 1))) ((>= i count) result)
        (set! result (concat result str))))))

(defvar *slash-help-usage*
  "/help — list all commands
/help <cmd> — show details"
  "Usage text for /help command.")

;; ============================================================================
;; STARTUP MESSAGE
;; ============================================================================
(let* ((sep (if (termcap 'unicode?) " · " ", "))
       (term-type (termcap 'type))
       (encoding (termcap 'encoding))
       (color-name
        (let ((level (termcap 'color-level)))
          (cond
            ((= level 4) "truecolor")
            ((= level 3) "256-color")
            ((= level 2) "16-color")
            ((> level 0) "8-color")
            (#t nil))))
       (term-info
        (concat term-type (if color-name (concat sep color-name) "")
         (if (and (string? encoding) (not (string=? encoding "ASCII")))
           (concat sep encoding)
           ""))))
  (script-echo (concat "mudlark " *version*) :desc
   ":help for built-in commands, /help for scripts" :section
   (concat "Terminal\n" term-info)))

;; Register /help after startup banner so its banner appears second
(register-slash-command "/help" slash-help-handler "Help"
 :desc
 "Show help for slash commands"
 :aliases
 '("/doc")
 :usage
 *slash-help-usage*)

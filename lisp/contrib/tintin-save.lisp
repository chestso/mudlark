;; tintin-save.lisp - Write state to TinTin++ config file format
;;
;; Depends on: tintin-state.lisp, tintin-utils.lisp
;; ============================================================================
;; WRITE HELPERS
;; ============================================================================
;; Reconstruct color spec string from stored (fg bg priority) highlight data
(defun tintin-reconstruct-color-spec (fg-color bg-color)
  (cond
    ((and fg-color bg-color) (concat fg-color ":" bg-color))
    (fg-color fg-color)
    (bg-color (concat ":" bg-color))
    (#t "")))

;; ============================================================================
;; STATE WRITING
;; ============================================================================
;; Write TinTin++ state to file in TinTin++ command syntax
(defun tintin-save-state (filename)
  (let ((file (open filename "w")))
    ;; Header
    (write-line file "// mudlark state file")
    (write-line file "")
    ;; Custom colors (mudlark extension, before highlights that may reference them)
    (if (> (hash-count *tintin-custom-colors*) 0)
      (progn (write-line file "// Colors")
        (let ((entries (hash-entries *tintin-custom-colors*)))
          (do ((i 0 (+ i 1))) ((>= i (length entries)))
            (let* ((entry (list-ref entries i))
                   (name (car entry))
                   (spec (cdr entry)))
              (write-line file (concat "#color {" name "} {" spec "}")))))
        (write-line file "")))
    ;; Aliases
    (if (> (hash-count *tintin-aliases*) 0)
      (progn (write-line file "// Aliases")
        (let ((entries (hash-entries *tintin-aliases*)))
          (do ((i 0 (+ i 1))) ((>= i (length entries)))
            (let* ((entry (list-ref entries i))
                   (name (car entry))
                   (data (cdr entry))
                   (commands (car data)))
              (write-line file (concat "#alias {" name "} {" commands "}")))))
        (write-line file "")))
    ;; Variables
    (if (> (hash-count *tintin-variables*) 0)
      (progn (write-line file "// Variables")
        (let ((entries (hash-entries *tintin-variables*)))
          (do ((i 0 (+ i 1))) ((>= i (length entries)))
            (let* ((entry (list-ref entries i))
                   (name (car entry))
                   (value (cdr entry)))
              (write-line file (concat "#variable {" name "} {" value "}")))))
        (write-line file "")))
    ;; Highlights
    (if (> (hash-count *tintin-highlights*) 0)
      (progn (write-line file "// Highlights")
        (let ((entries (hash-entries *tintin-highlights*)))
          (do ((i 0 (+ i 1))) ((>= i (length entries)))
            (let* ((entry (list-ref entries i))
                   (pattern (car entry))
                   (data (cdr entry))
                   (fg-color (car data))
                   (bg-color (cadr data))
                   (color-spec
                    (tintin-reconstruct-color-spec fg-color bg-color)))
              (write-line file
               (concat "#highlight {" pattern "} {" color-spec "}")))))
        (write-line file "")))
    ;; Actions
    (if (> (hash-count *tintin-actions*) 0)
      (progn (write-line file "// Actions")
        (let ((entries (hash-entries *tintin-actions*)))
          (do ((i 0 (+ i 1))) ((>= i (length entries)))
            (let* ((entry (list-ref entries i))
                   (pattern (car entry))
                   (data (cdr entry))
                   (commands (car data))
                   (priority (cadr data)))
              (write-line file
               (concat "#action {" pattern "} {" commands "}"
                (if (= priority 5)
                  ""
                  (concat " {" (number->string priority) "}")))))))
        (write-line file "")))
    ;; Settings
    (write-line file "// Settings")
    (write-line file
     (concat "#config {speedwalk} {" (if *tintin-speedwalk-enabled* "on" "off")
      "}"))
    (write-line file
     (concat "#config {speedwalk diagonals} {"
      (if *tintin-speedwalk-diagonals* "on" "off") "}"))
    (write-line file "")
    ;; Close file
    (close file)
    filename))

;; ============================================================================
;; COMMAND HANDLER
;; ============================================================================
;; Handle #write command
;; args: (filename)
(defun tintin-handle-write (args)
  "Handle #write command (write TinTin++ state to file)."
  (let ((filename (tintin-strip-braces (list-ref args 0))))
    (set! filename (expand-path filename))
    (tintin-save-state filename)
    (tintin-command-echo (concat "Written to '" filename "'\r\n"))
    ""))

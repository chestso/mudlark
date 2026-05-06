;; build-aux/spell-translator/spell-translator-suggest.lisp - For each unique
;; garbled word from the input file (one utterance per line, already filtered
;; to garbled-only by the shell wrapper), emit
;; "<garbled-word>\t<algorithmic-translation>" with *spell-dictionary* cleared.
;; The shell wrapper spell-checks the translation column with hunspell to
;; surface candidates for *spell-dictionary*.
;;
;; Driven by build-aux/spell-translator/spell-translator-suggest.sh.

(load "tests/test-helpers.lisp")
(load "lisp/contrib/spell-translator.lisp")

;; Clear *spell-dictionary* — the whole point is to see what the cipher
;; algorithm produces with no overrides.
(do ((keys (hash-keys *spell-dictionary*) (cdr keys))) ((null? keys))
  (hash-remove! *spell-dictionary* (car keys)))

(if (null? *command-line-args*)
  (error "Usage: bloom-repl build-aux/spell-translator/spell-translator-suggest.lisp -- <utterance-file>"))

(define *utterance-file* (car *command-line-args*))
(define *raw* (read-file-raw *utterance-file*))
(define *utterances*
  (filter (lambda (s) (> (length s) 0))
          (map string-trim (split *raw* "\n"))))

;; Dedupe by garbled word: hash *seen* maps garbled -> algorithmic translation.
(define *seen* (make-hash-table))

(defun record-word (g)
  (if (and (> (length g) 0) (not (hash-ref *seen* g)))
    (hash-set! *seen* g (translate-garbled-word g))))

(do ((rest *utterances* (cdr rest))) ((null? rest))
  (do ((words (split (car rest) " ") (cdr words))) ((null? words))
    (record-word (car words))))

;; Emit TSV. Stdout only — the shell wrapper handles all reporting.
(do ((keys (hash-keys *seen*) (cdr keys))) ((null? keys))
  (let ((g (car keys)))
    (format #t "~A	~A~%" g (hash-ref *seen* g))))

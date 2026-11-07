;; A user-input-hook that consumes the line "async" and sends it
;; asynchronously with telnet-send.
;;
;; The send goes out through the event loop, after the submit path is
;; done: the frame has to learn that the server owes an answer from the
;; send itself, not from the submit. This is the path the pending-answer
;; row has to cover.
(defun async-send-hook (text)
  "Consume \"async\" and send \"delayed\" asynchronously; pass anything else through."
  (if (string=? text "async")
    (progn (telnet-send "delayed") nil)
    text))

(add-hook 'user-input-hook 'async-send-hook)

(in-package 'sandbox)
; (use-package 'connector)

;; ---------------- Convenience: generic parser helper ----------------

;; Build a connector event from entity, request, action, and system name
(defun build-event (entity req action sys-name)
  (cc:infof (sorted-map "event" (sorted-map
    "oid" (get entity "claim_id")
    "key" (mk-uuid)
    "pdc" "private"
    "msp" "Org1MSP"
    "sys" sys-name
    "eng" action
    "req" req)) "event for {}" sys-name)
  (sorted-map
    "oid" (get entity "claim_id")
    "key" (mk-uuid)
    "pdc" "private"
    "msp" "Org1MSP"
    "sys" sys-name
    "eng" action
    "req" req))

(defun parse-generic-resp (resp &key skip-inner-error-check)
  (let* ([resp-body (get resp "response")]
         [resp-err  (get resp "error")])
    (when resp-err
      (set-exception-unexpected
        (format-string "unhandled response error: {}" resp-err)))
    (let* ([container (and resp-body (get resp-body "generic"))]
           [text-json (and container (get container "text"))]
           [parsed    (and text-json (json:load-string text-json))])
      (when (and (not skip-inner-error-check) (sorted-map? parsed))
        (let ([inner-error (get parsed "error")])
          (when inner-error
            (set-exception-unexpected
              (format-string "connector inner error: {}" inner-error)))))
      parsed)))

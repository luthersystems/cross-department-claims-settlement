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

;; ---------------- Helper: Get from resp or entity ----------------

;; Get a value from resp (explicit request) or entity (accumulated data), with optional default.
;; Priority: resp > entity > default
;; This abstracts the common pattern used in init handlers to support both:
;;   - Route invocations (data in resp)
;;   - Unified process transitions (data in entity, resp is empty)
(export 'get-from-resp-or-entity)
(defun get-from-resp-or-entity (key resp entity &optional default)
  (or (get resp key) (get entity key) default))

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

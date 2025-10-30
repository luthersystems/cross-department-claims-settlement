
;; -----------------------------------------------------------------------------
;; Example state handlers (invoice)
;; -----------------------------------------------------------------------------

;; 1: INVOICE_STATE_NEW -> INVOICE_STATE_S3_UPLOADED
(defun invoice-new-state-handler ()
  (labels
    ;; parse: validate + extract fields for this step (not persisted unless staged)
    ([parse (resp entity)
      (let* ([file-content (get resp "file_content")]
             [file-name    (get resp "file_name")]
             [bucket-name  (get resp "bucket_name")])
        (sorted-map
          "file_content" file-content
          "file_name"    file-name
          "bucket_name"  bucket-name))]

     ;; ephemeral: keep raw file content until we see S3 upload succeed
     [stage-ephemeral (entity parsed accessors)
      (vector
        (sorted-map :key "file_content"
                    :value (get parsed "file_content")
                    :drop-state "INVOICE_STATE_S3_UPLOADED"))]

     ;; durable: persist metadata
     [stage-durable (entity parsed accessors)
      (sorted-map
        "file_name"   (get parsed "file_name")
        "bucket_name" (get parsed "bucket_name"))]

     ;; events:  S3 upload using parsed content + durable metadata
     [create-events (entity parsed accessors)
      (let* ([file-name   (get entity "file_name")]
             [bucket-name (get entity "bucket_name")]
             [content     (get parsed "file_content")])
        (vector
          (mk-s3-upload-event entity content file-name bucket-name)))])
    (mk-state-handler
      :next            "INVOICE_STATE_S3_UPLOADED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))


;; 2: INVOICE_STATE_S3_UPLOADED -> INVOICE_STATE_S3_RETRIEVED
(defun invoice-s3-uploaded-state-handler ()
  (labels
    ;; parse S3 upload response (domain helper)
    ([parse (resp entity)
      (parse-s3-resp resp)]

     ;; no new ephemerals
     [stage-ephemeral (entity parsed accessors) ()]

     ;; no durable changes
     [stage-durable (entity parsed accessors) ()]

     ;; events: request S3 GET; demonstrate ephem-get before purge
     ;; events: register an HTTP webhook endpoint for claim updates
      ;; events: register an HTTP webhook endpoint for claim updates
      ; [create-events (entity parsed accessors)
      ;   (let* ([invoice-id (get entity "invoice_id")]
      ;          [path (format-string "/claims/update-status/%s" invoice-id)] ; maybe registering every ID is not great. Pattern match better
      ;          [opts (sorted-map "id" invoice-id "allow_unsigned" true)])
      ;     (vector
      ;       (mk-httpwebhook-register-transition entity path opts)))])
     [create-events (entity parsed accessors)
      (let* ([entity-id    (get entity "invoice_id")]
             [get-ephem    (get accessors :get-ephem)]
             [file-content (get-ephem "file_content")])
        (vector (mk-s3-get-event entity)))])
  (mk-state-handler
    :next            "INVOICE_STATE_S3_RETRIEVED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; 3: INVOICE_STATE_S3_RETRIEVED -> INVOICE_STATE_MYSQL_VALIDATED
(defun invoice-s3-retrieved-state-handler ()
  (labels
    ;; parse GET response (string/bytes → string)
    ([parse (resp entity)
      (parse-s3-resp resp)]

     ;; keep raw S3 body temporarily, drop once MySQL update succeeds
     [stage-ephemeral (entity parsed accessors) ()]

     ;; durable: extract invoice_number
     [stage-durable (entity parsed accessors)
      (let* ([j (json:load-string parsed)]
             [inv-num (get j "invoice_number")])
        (sorted-map "invoice_number" inv-num))]

     ;; events: validate invoice in MySQL
     [create-events (entity parsed accessors)
      (vector
        (mk-mysql-select-invoices-by-numbers-event
          entity
          (list (get entity "invoice_number"))))])
  (mk-state-handler
    :next            "INVOICE_STATE_MYSQL_VALIDATED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))

;; 4: INVOICE_STATE_MYSQL_VALIDATED -> INVOICE_STATE_NOTIFY_SENT

; After confirming the invoice exists in MySQL, the system registers a pause
; and generates a unique request ID (register-pause-callback). It then sends an
; outbound webhook (http_webhook_create) to the partner’s API, embedding both
; the request ID and a callback URL that the partner will later call when ready. 
(defun invoice-mysql-validated-state-handler ()
  (labels
    ([parse (resp entity)
      (parse-mysql-select resp)]

     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors) ()]

     [create-events (entity parsed accessors)
      ;; register a pause for inbound webhook callback only
      (let* ([rid "update_payment_status"]  ;; must match webhook return path param ;TODO MAYBE WE APPEND THE INVOIC  ID
             [required-state "INVOICE_STATE_AWAITING_CALLBACK"])
        (register-pause-callback invoice-manager required-state entity rid)
        (cc:infof (sorted-map "req_id" rid "required_state" required-state)
                  "registered inbound-only callback; waiting for external POST")
        ;; no outbound events
        (vector))])
    (mk-state-handler
      :next            "INVOICE_STATE_AWAITING_CALLBACK"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))



;; 5: INVOICE_STATE_NOTIFY_SENT -> INVOICE_STATE_AWAITING_CALLBACK
; Once the webhook is successfully sent, the system stores the request ID,
; callback URL, and registration status for observability, then moves into a
; waiting state.

; THIS IS A RACE IF THEY CALL BACK IMMEDIATELY (very unlikely) so we store the
; new state... and move into INVOICE_STATE_NOTIFY_SENT Now this doesnt create
;events, it just adds some fields to the invoice and a new tx is created, moving
;the state to INVOICE_STATE_AWAITING_CALLBACK

; so if a request comes in BEFORE that transition has happened, the request ID
; is registered, and is tied to the "handler" (invoice)... if the request comes
; in, the handler 'handle method is invoked with the OID. This pulls back the
; invoice and run-state-step runs against it. run-state-step's first move is
; this: [state (get instance "state")] It then uses that to find the set of
; functions it will use [spec (lookup-state-spec state)] So if the state spec IS
; still in the wrong state it will try execute for INVOICE_STATE_NOTIFY_SENT

; ;
; ;
; (defun invoice-notify-sent-state-handler ()
;   (labels
;     ([parse (resp entity)
;       (let* ([hwc         (get resp "http_webhook_create")]
;              [reg-resp    (and hwc (get hwc "register_response"))]
;              [rid         (and reg-resp (get reg-resp "id"))]
;              [endpoint    (and reg-resp (get reg-resp "endpoint_url"))]
;              [status      (and reg-resp (get reg-resp "status"))])
;         (sorted-map
;           "request_id"    rid
;           "callback_url"  endpoint
;           "notify_status" (to-string (default status ""))))]

;      ;; keep it simple: no ephemerals here
;      [stage-ephemeral (entity parsed accessors) ()]

;      ;; persist what we learned for observability
;      [stage-durable (entity parsed accessors)
;       (sorted-map
;         "pending_request_id" (get parsed "request_id")
;         "callback_url"       (get parsed "callback_url")
;         "notify_status"      (get parsed "notify_status"))]

;      ;; nothing to emit; we’ve just recorded the notify result
;      [create-events (entity parsed accessors) (vector)])
;   (mk-state-handler
;     :next            "INVOICE_STATE_AWAITING_CALLBACK"
;     :parse           parse
;     :stage-ephemeral stage-ephemeral
;     :stage-durable   stage-durable
;     :create-events   create-events)))

;; 6: INVOICE_STATE_AWAITING_CALLBACK -> INVOICE_STATE_MYSQL_UPDATED
;When the partner POSTs back to the callback URL (which includes the request
; ID), the inbound http_webhook_return connector receives it. The system matches
; the callback to the paused request, resumes the workflow, parses the partner’s
; response, and updates the invoice status in MySQL.
(defun invoice-awaiting-callback-state-handler ()
  (labels
    ;; Parse the webhook body you receive later at /update-payment-status/{request_id}
    ([parse (resp entity)
      (cc:infof (sorted-map "resp" resp) "webhook callback received")
      (sorted-map
        "status"     (to-string (default (get resp "status") ""))
        "claim_id"   (get resp "claimID")
        "payment_id" (get resp "paymentID"))]

     [stage-ephemeral (entity parsed accessors) ()]

     ;; Optional: keep callback status on the entity for observability
     [stage-durable (entity parsed accessors)
      (sorted-map "callback_status" (get parsed "status"))]

     ;; On callback, proceed to update MySQL using the invoice_number we already saved
     [create-events (entity parsed accessors)
      (let* ([inv-num (get entity "invoice_number")])
        (vector
          (mk-mysql-update-invoice-status-event
            entity
            (list inv-num))))])
            
  (mk-state-handler
    :next            "INVOICE_STATE_MYSQL_UPDATED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))

;; 7: INVOICE_STATE_MYSQL_UPDATED -> INVOICE_STATE_DONE
(defun invoice-mysql-updated-state-handler ()
  (labels
    ;; parse MySQL UPDATE/EXEC response
    ([parse (resp entity)
      (parse-mysql-exec resp)]

     ;; final cleanups if any (none here)
     [stage-ephemeral (entity parsed accessors) ()]

     ;; no durable changes
     [stage-durable (entity parsed accessors) ()]

     ;; no further events
     [create-events (entity parsed accessors)
      (vector)])
  (mk-state-handler
    :next            "INVOICE_STATE_DONE"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))
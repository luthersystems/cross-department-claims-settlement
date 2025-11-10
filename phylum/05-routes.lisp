(in-package 'sandbox)

(defendpoint "upload_claim_wf5" (req)
  (let* ([policy-id (or (get req "policy_id")
                        (set-exception-business "missing policy_id"))]

         ;; Step 1: create new object -> commits a tx (no events)
         [claim     (new-connector-object claim-manager)]
         [claim-id  (get claim "claim_id")]

         ;; Step 2: The init state's parse expects a CH response style input
         [chresp    (sorted-map "policy_id" policy-id)])

    ;; Step 3: trigger flow
    (trigger-connector-object claim-manager claim-id chresp)

    (route-success
      (sorted-map
        "claim_id" claim-id
        "state"    "CLAIM_STATE_ORACLE_RETRIEVED"))))

(defendpoint "update_payment_status_handler" (req)
  ;; req is empty/placeholder; ignore it and use transient instead
  (let* ([raw (transient:get "$ch_rep:0")]
         [env (if (string? raw) (json:parse raw) raw)]      ;; transient may already be a map
         [_   (when (nil? env) (set-exception-business "missing transient payload $ch_rep:0"))]
         [body        (get env "body")]
         [headers     (get env "headers")]
         [operationId (get env "operationId")]
         [method      (get env "method")]
         [path        (get env "path")]
         [timestamp   (get env "timestamp")]
         [claim-id    (get body "claimID")]
         [payment-id  (get body "paymentID")]
         [status      (get body "status")])

      ;; Validate claim exists
      (let* ([claim (claim-manager 'get claim-id)]
             [_     (when (nil? claim)
                      (set-exception-business (format-string "unknown claim_id: {}" claim-id)))]
             [claim-state (claim 'entity-state)])

        ;; Enforce initial state
        (when (not (equal? claim-state "CLAIM_STATE_AWAITING_APPROVAL"))
          (set-exception-business
            (format-string "invalid claim state: expected CLAIM_STATE_AWAITING_APPROVAL, got {}" claim-state)))

    
        ;; dev logs
    (cc:infof (sorted-map
                "op" operationId
                "method" method
                "path" path
                "claimID" claim-id
                "paymentID" payment-id
                "status" status
                "headers" headers
                "timestamp" timestamp)
              "parsed transient")

              ; get claim:
              ; if claim state != CLAIM_STATE_APPROVED error

    (trigger-connector-object 
      claim-manager 
      claim-id 
      (sorted-map "payment_id" payment-id "status" status))

    (route-success
      (sorted-map
        "claim_id" claim-id
        "state"    "CLAIM_STATE_ORACLE_RETRIEVED")))))

; (defun mk-invoice-oid-index-key (invoice-id)
;   ;; Namespaced key. Use sidedb "private" for privacy (preferred), fall back OK.
;   (join-index-cols "sandbox" "invoice_oid_idx" invoice-id))


; (defun index-get-oid-by-invoice (invoice-id)
;   ;; Prefer sidedb; optionally fall back to statedb for older data.
;   (let* ([k (mk-invoice-oid-index-key invoice-id)]
;          [oid (or (sidedb:get k) (statedb:get k))])
;     oid))

; (defendpoint "update_invoice" (req)
;   (let* ([invoice-id (or (get req "invoice_id")
;                          (set-exception-business "missing invoice_id"))]
;          [oid (index-get-oid-by-invoice invoice-id)]
;          [_ (when (nil? oid)
;               (set-exception-business
;                 (format-string "unknown invoice_id: {}" invoice-id)))]
;          ;; Build a normalized "connector response" shape for your object.
;          ;; Keep this small, normalized, and versionable.
;          [update-body (sorted-map
;                         "invoice_id" invoice-id
;                         "status"     (get req "status")
;                         "paid_at"    (get req "paid_at")
;                         "amount"     (get req "amount")
;                         "currency"   (get req "currency")
;                         "metadata"   (default (get req "metadata") (sorted-map)))]
;          ;; Wrap as a response envelope your object's `handle` knows how to parse.
;          ;; Here we use a namespaced key to make intent explicit.
;          [resp (sorted-map "response"
;                            (sorted-map "update_invoice" update-body))]

;          ;; Choose the factory that owns these objects.
;          ;; If invoices belong to your claims FSM, use `claims` (from claim.lisp).
;          ;; Otherwise, swap in your own `invoices` factory.
;          [updated-obj (trigger-connector-object claims oid resp)])
;     (route-success
;       (sorted-map
;         "status" "OK"
;         "routed_oid" (to-string oid)
;         "updated" (default updated-obj (sorted-map))))))

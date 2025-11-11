(in-package 'sandbox)

(use-package 'connector)

;; Build input parameters for WF5 from a request map.
;; Provides sensible defaults so chaining from WF4 can reuse this helper.
(defun build-wf5-inputs (req)
  (let* ([policy-id (or (get req "policy_id") (set-exception-business "missing policy_id"))]
         [existing-claim-id (get req "claim_id")]
         [new-claim (and (nil? existing-claim-id) (new-connector-object claim-manager-wf5))]
         [claim-id (or existing-claim-id (get new-claim "claim_id"))]
         [_ (when new-claim (claim-manager-wf5 'put (assoc new-claim "policy_id" policy-id)))]
         [sap-overrides (or (get req "sap") (sorted-map))]
         [sap (sorted-map
                "payment_id"     (or (get sap-overrides "payment_id") "PAYM-002")
                "invoice_id"     (or (get sap-overrides "invoice_id") "INV-1002")
                "reference"      (or (get sap-overrides "reference") "Batch-Nov-01")
                "vendor_id"      (or (get sap-overrides "vendor_id") "VEND-001")
                "amount"         (or (get sap-overrides "amount") 2500.00)
                "currency"       (or (get sap-overrides "currency") "USD")
                "payment_method" (or (get sap-overrides "payment_method") "EFT")
                "payment_date"   (or (get sap-overrides "payment_date") "2025-11-06")
                "status"         (or (get sap-overrides "status") "PENDING"))]
         [chain-to-wf5 (normalize-bool (get req "chain_to_wf5") true)])
    (sorted-map
      "claim_id"    claim-id
      "policy_id"   policy-id
      "sap"         sap
      "chain_to_wf5" chain-to-wf5)))

(defendpoint "upload_claim_wf5" (req)
  (cc:infof (sorted-map "req" req) "upload_claim_wf5 called")
  (let* ([inputs (build-wf5-inputs req)]
         [result (invoke-workflow claim-manager-wf5 inputs)])
    (cc:infof (sorted-map "result" result) "upload_claim_wf5 completed")
    (route-success (sorted-map "claim_id" (get result "claim_id")))))

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
      (let* ([claim (claim-manager-wf5 'get claim-id)]
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
      claim-manager-wf5
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

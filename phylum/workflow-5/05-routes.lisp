(in-package 'cdcs)



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
                "payment_id"     (or (get sap-overrides "payment_id") *wf5-default-sap-payment-id*)
                "invoice_id"     (or (get sap-overrides "invoice_id") *wf5-default-sap-invoice-id*)
                "reference"      (or (get sap-overrides "reference") *wf5-default-sap-reference*)
                "vendor_id"      (or (get sap-overrides "vendor_id") *wf5-default-sap-vendor-id*)
                "amount"         (or (get sap-overrides "amount") *wf5-default-sap-amount*)
                "currency"       (or (get sap-overrides "currency") *wf5-default-sap-currency*)
                "payment_method" (or (get sap-overrides "payment_method") *wf5-default-sap-payment-method*)
                "payment_date"   (or (get sap-overrides "payment_date") *wf5-default-sap-payment-date*)
                "status"         (or (get sap-overrides "status") *wf5-default-sap-status*))])
    (sorted-map
      "claim_id"    claim-id
      "policy_id"   policy-id
      "sap"         sap)))

(defendpoint "upload_claim_wf5" (req)
  (let* ([inputs (build-wf5-inputs req)]
         [result (invoke-workflow claim-manager-wf5 inputs)])
    (route-success (sorted-map "claim_id" (get result "claim_id")
                               "state" (get result "state")))))

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

    (trigger-connector-object 
      claim-manager-wf5
      claim-id 
      (sorted-map "payment_id" payment-id "status" status))

    (route-success
      (sorted-map
        "claim_id" claim-id
        "state"    claim-state)))))

(in-package 'cdcs)

;; Build input parameters for the unified claim process from a request map
;; This endpoint invokes the entire process (WF1 → WF2 → WF3 → WF4 → WF5)
(defun build-process-inputs (req)
  (let* ([policy-id (or (get req "policy_id")
                        (set-exception-business "missing policy_id"))])
    (sorted-map
      "policy_id"          policy-id
      "guidewire_claim_id" (get req "guidewire_claim_id")
      "gw_claim_id"        (get req "gw_claim_id")
      "signer_email"       (get req "signer_email")
      "signer_name"        (get req "signer_name")
      "invoice_amount"     (get req "invoice_amount")
      "originator_name"    (get req "originator_name")
      "recipient_name"     (get req "recipient_name")
      "issue_date"         (get req "issue_date"))))

(defendpoint "invoke_process" (req)
  (let* ([inputs (build-process-inputs req)]
         [result (invoke-workflow claim-manager inputs)])
    (route-success (sorted-map "claim_id" (get result "claim_id")
                               "state" (get result "state")))))

;; Get claim state endpoint - returns current state of a claim
(defendpoint-get "get_claim_state" (req)
  (let* ([claim-id (or (get req "claim_id")
                       (set-exception-business "missing claim_id"))]
         [claim (claim-manager 'get claim-id)]
         [_     (when (nil? claim)
                  (set-exception-business (format-string "unknown claim_id: {}" claim-id)))]
         [claim-state (claim 'entity-state)])
    (route-success (sorted-map "claim_id" claim-id
                               "state"    claim-state))))

;; -----------------------------------------------------------------------------
;; Inbound REST handlers for unified process
;; These use claim-manager (unified process manager)
;; -----------------------------------------------------------------------------

;; Handler for payment status updates - uses unified claim-manager
(defendpoint "update_payment_status_handler" (req)
  ;; Handler for inbound REST endpoint /payment/update-payment-status
  ;; Uses unified claim-manager
  ;; req is empty/placeholder; ignore it and use transient instead
  (let* ([raw (transient:get "$ch_rep:0")]
         [env (if (string? raw) (json:parse raw) raw)]      ;; transient may already be a map
         [_   (when (nil? env) (set-exception-business "missing transient payload $ch_rep:0"))]
         [body        (get env "body")]
         [claim-id    (get body "claimID")]
         [payment-id  (get body "paymentID")]
         [status      (get body "status")])

      ;; Validate claim exists in unified claim-manager
      (let* ([claim (claim-manager 'get claim-id)]
             [_     (when (nil? claim)
                      (set-exception-business (format-string "unknown claim_id: {}" claim-id)))]
             [claim-state (claim 'entity-state)])

        ;; Enforce correct state for WF5
        (when (not (equal? claim-state "WF5_CLAIM_STATE_AWAITING_PAYMENT_UPDATE"))
          (set-exception-business
            (format-string "invalid claim state: expected WF5_CLAIM_STATE_AWAITING_PAYMENT_UPDATE, got {}" claim-state)))

    (trigger-connector-object 
      claim-manager
      claim-id 
      (sorted-map "payment_id" payment-id "status" status))

    (route-success
      (sorted-map
        "claim_id" claim-id
        "state"    claim-state)))))

;; Handler for contract signed - uses unified claim-manager
(defendpoint "contract_signed_handler" (req)
  ;; Handler for inbound REST endpoint /contract/contract-signed
  ;; Uses unified claim-manager
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
         [signed-by   (get body "signedBy")]
         [verified-by (or (get body "verifiedBy") "jack.clarke@luthersystems.com")])

      ;; Validate required fields
      (when (nil? claim-id)
        (set-exception-business "missing claimID in request body"))
      (when (nil? signed-by)
        (set-exception-business "missing signedBy in request body"))

      ;; Get existing claim from unified claim-manager - error if not found
      (let* ([claim (claim-manager 'get claim-id)]
             [_     (when (nil? claim)
                      (set-exception-business (format-string "unknown claim_id: {}" claim-id)))]
             [claim-state-before (claim 'entity-state)])

        ;; Enforce that we're in the waiting state
        (when (not (equal? claim-state-before "WF4_CLAIM_STATE_WAITING_FOR_SIGNATURE"))
          (cc:warnf (sorted-map
                      "claim_id" claim-id
                      "expected_state" "WF4_CLAIM_STATE_WAITING_FOR_SIGNATURE"
                      "actual_state" claim-state-before)
                    "contract_signed_handler: invalid state, aborting")
          (set-exception-business
            (format-string "invalid claim state: expected WF4_CLAIM_STATE_WAITING_FOR_SIGNATURE, got {}" claim-state-before)))

        ;; Trigger state transition using unified claim-manager
        ;; Process WAITING_FOR_SIGNATURE handler with signedBy/verifiedBy data
        ;; The handler will store the data and transition to CONTRACT_SIGNED automatically
        (let* ([updated-entity (trigger-connector-object 
                                  claim-manager
                                  claim-id 
                                  (sorted-map "signedBy" signed-by
                                             "verifiedBy" verified-by
                                             "claim_id" claim-id))]
               [claim-state-after (if updated-entity (get updated-entity "state") claim-state-before)])

          (route-success
            (sorted-map
              "claim_id" claim-id
              "state"    claim-state-after
              "signed_by" signed-by
              "verified_by" verified-by))))))


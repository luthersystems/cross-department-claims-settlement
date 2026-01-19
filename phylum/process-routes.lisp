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

;; Unified upload claim endpoint: POST specifies workflow_name so we can route
;; to the correct workflow manager without relying on which RPC was called.
(defendpoint "upload_claim" (req)
  (let* ([workflow-name (or (get req "workflow_name")
                            (set-exception-business "missing workflow_name"))]
         [workflow-name-lower (string:lowercase workflow-name)]
         [result
          (cond
            ((equal? workflow-name-lower "wf1")
             (invoke-workflow claim-manager-wf1
                              (sorted-map "policy_id" (or (get req "policy_id")
                                                          (set-exception-business "missing policy_id")))))

            ((equal? workflow-name-lower "wf2")
             (invoke-workflow claim-manager-wf2
                              (sorted-map "policy_id" (or (get req "policy_id")
                                                          (set-exception-business "missing policy_id"))
                                          "guidewire_claim_id" (or (get req "guidewire_claim_id")
                                                                   (get req "gw_claim_id")
                                                                   (set-exception-business "missing guidewire_claim_id")))))

            ((equal? workflow-name-lower "wf3")
             (invoke-workflow claim-manager-wf3
                              (sorted-map "claim_id" (or (get req "claim_id")
                                                         (set-exception-business "missing claim_id"))
                                          "invoice_amount" (or (get req "invoice_amount")
                                                               (set-exception-business "missing invoice_amount"))
                                          "signer_name" (or (get req "signer_name")
                                                            (set-exception-business "missing signer_name"))
                                          "signer_email" (or (get req "signer_email")
                                                             (set-exception-business "missing signer_email"))
                                          "originator_name" (get req "originator_name")
                                          "recipient_name" (get req "recipient_name")
                                          "issue_date" (get req "issue_date"))))

            ((equal? workflow-name-lower "wf4")
             (invoke-workflow claim-manager-wf4
                              (sorted-map
                                "policy_id" (get req "policy_id")
                                "customer_id" (or (get req "customer_id") (set-exception-business "missing customer_id"))
                                "reference_number" (or (get req "reference_number") (set-exception-business "missing reference_number"))
                                "due_date" (or (get req "due_date") (set-exception-business "missing due_date"))
                                "is_inclusive_tax" (or (get req "is_inclusive_tax") (set-exception-business "missing is_inclusive_tax"))
                                "line_items" (or (get req "line_items") (set-exception-business "missing line_items"))
                                "claim_id" (get req "claim_id")
                                "currency_code" (get req "currency_code"))))

            ((equal? workflow-name-lower "wf5")
             (invoke-workflow claim-manager-wf5
                              (sorted-map "policy_id" (or (get req "policy_id")
                                                          (set-exception-business "missing policy_id"))
                                          "claim_id" (get req "claim_id"))))

            ;; Allow using this unified POST for the full process as well.
            ((equal? workflow-name-lower "process")
             (let* ([inputs (build-process-inputs req)])
               (invoke-workflow claim-manager inputs)))

            (:else
             (set-exception-business
               (format-string "invalid workflow_name: {} (must be wf1, wf2, wf3, wf4, wf5, or process)" workflow-name))))])
    (route-success (sorted-map "claim_id" (get result "claim_id")
                               "state" (get result "state")))))

;; Get claim state endpoint - returns current state of a claim
(defendpoint-get "get_claim_state" (req)
  (let* ([claim-id (or (get req "claim_id")
                       (set-exception-business "missing claim_id"))]
         [workflow-name (or (get req "workflow_name")
                            (set-exception-business "missing workflow_name"))]
         [workflow-name-lower (string:lowercase workflow-name)]
         [manager (or (get workflow-registry workflow-name-lower)
                      (set-exception-business (format-string "unknown workflow_name: {}" workflow-name)))]
         [claim (manager 'get claim-id)]
         [_     (when (nil? claim)
                  (set-exception-business (format-string "unknown claim_id: {} for workflow: {}" claim-id workflow-name-lower)))]
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
  ;; Uses workflow-specific manager selected by workflow_name in body
  ;; req is empty/placeholder; ignore it and use transient instead
  (let* ([raw (transient:get "$ch_rep:0")]
         [env (if (string? raw) (json:parse raw) raw)]      ;; transient may already be a map
         [_   (when (nil? env) (set-exception-business "missing transient payload $ch_rep:0"))]
         [body        (get env "body")]
         [workflow-name (or (get body "workflow_name")
                            (set-exception-business "missing workflow_name in request body"))]
         [workflow-name-lower (string:lowercase workflow-name)]
         [manager (or (get workflow-registry workflow-name-lower)
                      (set-exception-business (format-string "unknown workflow_name: {}" workflow-name)))]
         [claim-id    (get body "claimID")]
         [payment-id  (get body "paymentID")]
         [status      (get body "status")])

      ;; Validate claim exists in selected manager
      (let* ([claim (manager 'get claim-id)]
             [_     (when (nil? claim)
                      (set-exception-business (format-string "unknown claim_id: {} for workflow: {}" claim-id workflow-name-lower)))]
             [claim-state (claim 'entity-state)])

        ;; Enforce correct state for WF5
        (when (not (equal? claim-state "WF5_CLAIM_STATE_AWAITING_PAYMENT_UPDATE"))
          (set-exception-business
            (format-string "invalid claim state: expected WF5_CLAIM_STATE_AWAITING_PAYMENT_UPDATE, got {}" claim-state)))

    (trigger-connector-object 
      manager
      claim-id 
      (sorted-map "claim_id" claim-id "payment_id" payment-id "status" status))

    (route-success
      (sorted-map
        "claim_id" claim-id
        "state"    claim-state)))))

;; Handler for contract signed - uses unified claim-manager
(defendpoint "contract_signed_handler" (req)
  ;; Handler for inbound REST endpoint /contract/contract-signed
  ;; Uses workflow-specific manager selected by workflow_name in body
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
         [workflow-name (or (get body "workflow_name")
                            (set-exception-business "missing workflow_name in request body"))]
         [workflow-name-lower (string:lowercase workflow-name)]
         [manager (or (get workflow-registry workflow-name-lower)
                      (set-exception-business (format-string "unknown workflow_name: {}" workflow-name)))]
         [claim-id    (get body "claimID")]
         [signed-by   (get body "signedBy")]
         [verified-by (or (get body "verifiedBy") "jack.clarke@luthersystems.com")])

      ;; Validate required fields
      (when (nil? claim-id)
        (set-exception-business "missing claimID in request body"))
      (when (nil? signed-by)
        (set-exception-business "missing signedBy in request body"))

      ;; Get existing claim from selected manager - error if not found
      (let* ([claim (manager 'get claim-id)]
             [_     (when (nil? claim)
                      (set-exception-business (format-string "unknown claim_id: {} for workflow: {}" claim-id workflow-name-lower)))]
             [claim-state-before (claim 'entity-state)])
            ;  [teams-thread-id (get claim "teams_thread_id")]
            ;  [teams-message-id (get claim "teams_message_id")])



        ;; Enforce that we're in the waiting state
        (when (not (equal? claim-state-before "WF4_CLAIM_STATE_WAITING_FOR_SIGNATURE"))
          (cc:warnf (sorted-map
                      "claim_id" claim-id
                      "expected_state" "WF4_CLAIM_STATE_WAITING_FOR_SIGNATURE"
                      "actual_state" claim-state-before)
                    "contract_signed_handler: invalid state, aborting")
          (set-exception-business
            (format-string "invalid claim state: expected WF4_CLAIM_STATE_WAITING_FOR_SIGNATURE, got {}" claim-state-before)))

        ;; Trigger state transition using selected manager
        ;; Process WAITING_FOR_SIGNATURE handler with signedBy/verifiedBy data
        ;; The handler will store the data and transition to CONTRACT_SIGNED automatically
        (let* ([updated-entity (trigger-connector-object 
                                  manager
                                  claim-id 
                                  (sorted-map "signedBy" signed-by
                                             "verifiedBy" verified-by
                                             "claim_id" claim-id))]
               [claim-state-after (if updated-entity (get updated-entity "state") claim-state-before)]
               [updated-teams-thread-id (if updated-entity (get updated-entity "teams_thread_id") nil)]
               [updated-teams-message-id (if updated-entity (get updated-entity "teams_message_id") nil)])

          (route-success
            (sorted-map
              "claim_id" claim-id
              "state"    claim-state-after
              "signed_by" signed-by
              "verified_by" verified-by))))))

;; Handler for invoice/payment signature notification - uses workflow-specific manager
(defendpoint "notify_invoice_signed_handler" (req)
  ;; Handler for inbound REST endpoint /invoice/invoice-signed
  ;; Uses workflow-specific manager selected by workflow_name in body
  ;; req is empty/placeholder; ignore it and use transient instead
  (let* ([raw (transient:get "$ch_rep:0")]
         [env (if (string? raw) (json:parse raw) raw)]      ;; transient may already be a map
         [_   (when (nil? env) (set-exception-business "missing transient payload $ch_rep:0"))]
         [body        (get env "body")]
         [workflow-name (or (get body "workflow_name")
                            (set-exception-business "missing workflow_name in request body"))]
         [workflow-name-lower (string:lowercase workflow-name)]
         [manager (or (get workflow-registry workflow-name-lower)
                      (set-exception-business (format-string "unknown workflow_name: {}" workflow-name)))]
         [claim-id    (get body "claimID")]
         [signed-by   (get body "signedBy")])

      ;; Validate required fields
      (when (nil? claim-id)
        (set-exception-business "missing claimID in request body"))
      (when (nil? signed-by)
        (set-exception-business "missing signedBy in request body"))

      ;; Get existing claim from selected manager - error if not found
      (let* ([claim (manager 'get claim-id)]
             [_     (when (nil? claim)
                      (set-exception-business (format-string "unknown claim_id: {} for workflow: {}" claim-id workflow-name-lower)))]
             [claim-state-before (claim 'entity-state)])

        ;; Enforce that we're in the waiting state
        (when (not (equal? claim-state-before "CLAIM_STATE_WAITING_FOR_PAYMENT_SIGNATURE"))
          (cc:warnf (sorted-map
                      "claim_id" claim-id
                      "expected_state" "CLAIM_STATE_WAITING_FOR_PAYMENT_SIGNATURE"
                      "actual_state" claim-state-before)
                    "notify_invoice_signed_handler: invalid state, aborting")
          (set-exception-business
            (format-string "invalid claim state: expected CLAIM_STATE_WAITING_FOR_PAYMENT_SIGNATURE, got {}" claim-state-before)))

        ;; Trigger state transition using selected manager
        ;; Process WAITING_FOR_PAYMENT_SIGNATURE handler with signedBy data
        (let* ([updated-entity (trigger-connector-object 
                                  manager
                                  claim-id 
                                  (sorted-map "signedBy" signed-by
                                             "claim_id" claim-id))]
               [claim-state-after (if updated-entity (get updated-entity "state") claim-state-before)])

          (route-success
            (sorted-map
              "claim_id" claim-id
              "state"    claim-state-after
              "signed_by" signed-by))))))


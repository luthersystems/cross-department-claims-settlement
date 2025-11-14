(in-package 'cdcs)



;; Note: Constants moved to 04-constants.lisp

;; Build input parameters for WF4 from a request map
;; Supports direct route invocation or chained workflow handoffs.
;; Minimal required fields: customer_id, reference_number, due_date, is_inclusive_tax, line_items
(defun build-wf4-inputs (req)
  (let* ([zoho-raw       (or (get req "zoho") (sorted-map))]
         [sharepoint-raw (or (get req "sharepoint") (sorted-map))]
         [servicenow-raw (or (get req "servicenow") (sorted-map))]
         ;; Extract claim_id from reference_number if not provided
         [claim-id (or (get req "claim_id")
                       (get req "reference_number")
                       (get zoho-raw "reference_number")
                       (set-exception-business "missing claim_id or reference_number"))]
         [policy-id (or (get req "policy_id") *wf4-default-policy-id*)]
         ;; Zoho fields - prioritize direct request fields, then zoho nested, then defaults
         [customer-id      (or (get req "customer_id")
                               (get zoho-raw "customer_id")
                               *wf4-default-customer-id*)]
         [reference-number (or (get req "reference_number")
                               (get zoho-raw "reference_number")
                               claim-id)]
         [due-date         (or (get req "due_date")
                               (get zoho-raw "due_date")
                               *wf4-default-due-date*)]
         [currency-code    (or (get req "currency_code")
                               (get zoho-raw "currency_code")
                               *wf4-default-currency-code*)]
         [inclusive-tax    (normalize-bool (or (get req "is_inclusive_tax")
                                               (get zoho-raw "is_inclusive_tax")
                                               *wf4-default-is-inclusive-tax*))]
         [line-items-raw   (or (get req "line_items")
                                (get zoho-raw "line_items"))]
         [line-items       (cond
                             ((vector? line-items-raw) line-items-raw)
                             ((nil? line-items-raw) *wf4-default-line-items*)
                             (:else (vector line-items-raw)))]
         [zoho (sorted-map
                 "customer_id"      customer-id
                 "reference_number" reference-number
                 "due_date"         due-date
                 "is_inclusive_tax" inclusive-tax
                 "currency_code"    currency-code
                 "line_items"       line-items)]
         ;; SharePoint - use defaults
         [sharepoint (sorted-map
                       "site_id"  (or (get sharepoint-raw "site_id")
                                      (get req "site_id")
                                      *wf4-default-sharepoint-site-id*)
                       "drive_id" (or (get sharepoint-raw "drive_id")
                                      (get req "drive_id")
                                      *wf4-default-sharepoint-drive-id*)
                       "item_id"  (or (get sharepoint-raw "item_id")
                                      (get req "item_id")
                                      *wf4-default-sharepoint-item-id*)
                       "filename" (or (get sharepoint-raw "filename")
                                      (get req "filename")
                                      *wf4-default-sharepoint-filename*))]
         ;; ServiceNow - use defaults
         [servicenow (sorted-map
                       "short_description" (or (get servicenow-raw "short_description")
                                                (get req "short_description")
                                                (format-string "Create incident for claim {}" claim-id))
                       "description"      (or (get servicenow-raw "description")
                                              (get req "description")
                                              *wf4-default-servicenow-description*)
                       "priority"         (or (get servicenow-raw "priority")
                                              (get req "priority")
                                              *wf4-default-servicenow-priority*)
                       "category"         (or (get servicenow-raw "category")
                                              (get req "category")
                                              *wf4-default-servicenow-category*)
                       "impact"           (or (get servicenow-raw "impact")
                                              (get req "impact")
                                              *wf4-default-servicenow-impact*)
                       "urgency"          (or (get servicenow-raw "urgency")
                                              (get req "urgency")
                                              *wf4-default-servicenow-urgency*)
                       "assignment_group" (or (get servicenow-raw "assignment_group")
                                              (get req "assignment_group")
                                              *wf4-default-servicenow-assignment-group*)
                       "caller_id"        (or (get servicenow-raw "caller_id")
                                              (get req "caller_id")))])
    (sorted-map
      "claim_id"   claim-id
      "policy_id"  policy-id
      "zoho"       zoho
      "sharepoint" sharepoint
      "servicenow" servicenow)))

(defendpoint "upload_claim_wf4" (req)
  (let* ([inputs (build-wf4-inputs req)]
         [result (invoke-workflow claim-manager-wf4 inputs)])
    (route-success (sorted-map "claim_id" (get result "claim_id")
                               "state" (get result "state")))))

(defendpoint "contract_signed_handler" (req)
  ;; Handler for inbound REST endpoint /contract-signed
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

      (cc:infof (sorted-map
                  "claim_id" claim-id
                  "signed_by" signed-by
                  "verified_by" verified-by
                  "operationId" operationId)
                "contract_signed_handler: received contract signed notification")

      ;; Validate required fields
      (when (nil? claim-id)
        (set-exception-business "missing claimID in request body"))
      (when (nil? signed-by)
        (set-exception-business "missing signedBy in request body"))

      ;; Get existing claim - error if not found
      (let* ([claim (claim-manager 'get claim-id)]
             [_     (when (nil? claim)
                      (set-exception-business (format-string "unknown claim_id: {}" claim-id)))]
             [claim-state-before (claim 'entity-state)])

        (cc:infof (sorted-map
                    "claim_id" claim-id
                    "state_before" claim-state-before)
                  "contract_signed_handler: continuing existing claim from unified process")

        ;; Enforce that we're in the waiting state (from unified process)
        (when (not (equal? claim-state-before "WF4_CLAIM_STATE_WAITING_FOR_SIGNATURE"))
          (cc:warnf (sorted-map
                      "claim_id" claim-id
                      "expected_state" "WF4_CLAIM_STATE_WAITING_FOR_SIGNATURE"
                      "actual_state" claim-state-before)
                    "contract_signed_handler: invalid state, aborting")
          (set-exception-business
            (format-string "invalid claim state: expected WF4_CLAIM_STATE_WAITING_FOR_SIGNATURE, got {}" claim-state-before)))

        (cc:infof (sorted-map
                    "claim_id" claim-id
                    "signed_by" signed-by
                    "verified_by" verified-by
                    "state_before" claim-state-before)
                  "contract_signed_handler: triggering state transition from WAITING_FOR_SIGNATURE")

        ;; Trigger state transition using unified claim-manager
        ;; First call: process WAITING_FOR_SIGNATURE handler with signedBy/verifiedBy data
        (let* ([transition-result-1 (trigger-connector-object 
                                      claim-manager
                                      claim-id 
                                      (sorted-map "signedBy" signed-by
                                                 "verifiedBy" verified-by
                                                 "claim_id" claim-id))]
               [claim-after-1 (claim-manager 'get claim-id)]
               [state-after-1 (if claim-after-1 (claim-after-1 'entity-state) nil)])
          
          (cc:infof (sorted-map
                      "claim_id" claim-id
                      "state_after_storage" state-after-1)
                    "contract_signed_handler: stored signature data, now transitioning to CONTRACT_SIGNED")
          
          ;; Second call: trigger transition to CONTRACT_SIGNED
          ;; The handler will read signedBy/verifiedBy from entity (stored by previous call)
          (let* ([transition-result-2 (trigger-connector-object 
                                        claim-manager
                                        claim-id 
                                        (sorted-map "claim_id" claim-id))]
                 [updated-claim (claim-manager 'get claim-id)]
                 [claim-state-after (if updated-claim (updated-claim 'entity-state) nil)])

            (cc:infof (sorted-map
                        "claim_id" claim-id
                        "state_before" claim-state-before
                        "state_after" claim-state-after
                        "transition_result" transition-result-2)
                      "contract_signed_handler: state transition completed")

            (route-success
              (sorted-map
                "claim_id" claim-id
                "state"    (or claim-state-after claim-state-before)
                "signed_by" signed-by
                "verified_by" verified-by)))))))

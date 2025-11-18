(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; Unified Process Registration: All workflows combined (WF1 → WF2 → WF3 → WF4 → WF5)
;; -----------------------------------------------------------------------------

;; Helper function to merge multiple state specs, with later specs overriding earlier ones
(defun merge-state-specs (&rest specs)
  (let* ([merged (sorted-map)])
    (map () (lambda (spec)
              (map () (lambda (key)
                        (assoc! merged key (get spec key)))
                   (keys spec)))
         specs)
    merged))

;; -----------------------------------------------------------------------------
;; Custom State Handlers (can be inserted anywhere in the process chain)
;; -----------------------------------------------------------------------------

;; Waiting state for payment signature - waits for inbound REST call
;; Sends Teams notification when entering this state
(defun waiting-for-payment-signature-state-handler ()
  (labels
    ([parse (resp entity)
      ;; Waiting state - accepts signedBy when external system calls payment signature endpoint
      (let* ([claim-id    (or (get resp "claim_id") (get entity "claim_id"))]
             [signed-by   (get resp "signedBy")]  ;; Only present when called from external endpoint
             [policy-id   (get entity "policy_id")]
             [amount      (get entity "amount")]
             [invoice-id  (get entity "zoho_invoice_id")]
             [thread-id   (get entity "teams_thread_id")]
             [message-id  (get entity "teams_message_id")])
        (when (nil? claim-id)
          (set-exception-business "missing claim_id"))
        (sorted-map
          "claim_id"    claim-id
          "signed_by"   signed-by
          "thread_id"   thread-id
          "message_id"  message-id
          "message"     (format-string
                          "📋 **Claim Payment Request**\n\n"
                          "**Claim ID:** {}\n"
                          "**Policy ID:** {}\n"
                          "**Amount:** {}\n"
                          "**Invoice ID:** {}\n"
                          "**Status:** Claim approved, invoice generated, contract signed\n"
                          "⏳ **Awaiting payment approval**\n\n"
                          "✅ Please review and approve payment for this claim."
                          (or claim-id "N/A")
                          (or policy-id "N/A")
                          (or amount "N/A")
                          (or invoice-id "N/A"))))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors)
      ;; Store signedBy if provided (from external endpoint)
      (let* ([has-signature (get parsed "signed_by")]
             [durable-result (if has-signature
                               (sorted-map "payment_signed_by" (get parsed "signed_by"))
                               ())])
        durable-result)]  ;; Empty map during unified process transition
     [create-events (entity parsed accessors)
      ;; Send Teams notification when entering waiting state
      ;; Get thread_id and message_id from entity (stored in WF1)
      ;; Always send message, even if signedBy is present (external endpoint call)
      (let* ([thread-id  (get entity "teams_thread_id")]
             [message-id (get entity "teams_message_id")]
             [message    (get parsed "message")]
             [has-signature (get parsed "signed_by")])
        ;; Send Teams message if we have thread/message IDs
        (if (and thread-id message-id)
          (vector (mk-teams-update-thread-event entity thread-id message-id message))
          (vector)))])  
    (mk-state-handler
      :next            "CLAIM_STATE_PAYMENT_TEAM_NOTIFIED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun payment-team-notified-state-handler ()
  (labels
    ([parse (resp entity) (sorted-map)]
    [stage-ephemeral (entity parsed accessors) (vector)]
    [stage-durable (entity parsed accessors) ()]
    [create-events (entity parsed accessors) (vector)])
    (mk-state-handler
      :next            "CLAIM_STATE_PAYMENT_TEAM_NOTIFIED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))
      
;; Combined state spec for the entire process
;; Merges all workflow state specs and overrides specific handlers for chaining
;; Custom states can be inserted anywhere in the chain
(set 'state-spec-claim
     (merge-state-specs
       ;; Base workflow specs (merged in order)
       state-spec-wf1
       state-spec-wf2
       state-spec-wf3
       state-spec-wf4  ;; workflow-4-edit (includes WAITING_FOR_SIGNATURE and CONTRACT_SIGNED states)
       ;; Custom states for payment signature flow
       (sorted-map
         "CLAIM_STATE_WAITING_FOR_PAYMENT_SIGNATURE" (waiting-for-payment-signature-state-handler)
         "CLAIM_STATE_PAYMENT_TEAM_NOTIFIED"         (payment-team-notified-state-handler))
  
       ;; Overrides for unified process chaining using after-storage hooks
       ;; Workflows transition to their DONE states, then hooks chain to the next workflow
       (sorted-map
         ;; WF1: chain to WF2 via hook
         "WF1_CLAIM_TEAMS_THREAD_CREATED"           (wf1-teams-thread-created-state-handler 
                                                      "WF2_CLAIM_STATE_INIT" 
                                                      (lambda (entity) 
                                                        (let* ([claim-id (get entity "claim_id")])
                                                          (cc:infof (sorted-map  "claim_id" claim-id) "WF1 completed - chaining to WF2 via after-storage hook")
                                                          (trigger-connector-object claim-manager claim-id ()))))

         ;; WF2: skip CUSTOM_VALIDATION_STATE, go directly to WF3
         "WF2_CLAIM_STATE_GUIDEWIRE_APPROVED"      (wf2-claim-guidewire-approved-state-handler
                                                      "WF3_CLAIM_STATE_INVOICE_INIT"
                                                      (lambda (entity)
                                                      (let* ([claim-id (get entity "claim_id")])
                                                          (cc:infof (sorted-map  "claim_id" claim-id) "WF2 completed - chaining to WF3 via after-storage hook")
                                                          ;; Update entity state to WF3's initial state, then trigger
                                                          (trigger-connector-object 
                                                            claim-manager 
                                                            claim-id 
                                                            ()))))
          ;; WF3: transition directly to WF4 init via hook
         "WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED" (wf3-invoice-email-dispatched-state-handler 
                                                       "WF4_CLAIM_STATE_INIT"
                                                       (lambda (entity)
                                                       (let* ([claim-id (get entity "claim_id")])
                                                          (cc:infof (sorted-map  "claim_id" claim-id) "WF3 completed - chaining to WF4 via after-storage hook")
                                                             (trigger-connector-object 
                                                               claim-manager 
                                                               claim-id 
                                                               ()))))
         
         ;; WF4: transition to waiting for payment signature instead of WF5
         "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED" (wf4-servicenow-incident-created-state-handler 
                                                         "CLAIM_STATE_WAITING_FOR_PAYMENT_SIGNATURE"
                                                         (lambda (entity)
                                                           (let* ([claim-id (get entity "claim_id")])
                                                             (cc:infof
                                                               (sorted-map "claim_id" claim-id)
                                                               "WF4 completed - chaining to WAITING_FOR_PAYMENT_SIGNATURE via after-storage hook")
                                                             ))))))

;; Unified claim manager for the entire process
;; Workflow chaining is handled via after-storage hooks in DONE states
(set 'claim-manager
     (singleton (mk-entity-manager
                 "claim"                    ;; entity kind
                 "claim_id"                 ;; primary key field
                 "WF1_CLAIM_STATE_NEW"      ;; initial state (start with WF1)
                 state-spec-claim)))

(register-connector-factory claim-manager)

;; Register workflow for easy invocation
(register-workflow "process" claim-manager)


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

;; Example: Custom validation/processing state that can be inserted between workflows
;; This demonstrates how to add custom states that aren't part of any specific workflow
(defun custom-validation-state-handler (&optional next-state after-storage-hook)
  (labels
    ([parse (resp entity)
       ;; Parse any incoming data or validate entity state
       ;; In this example, we'll just log some entity fields
       (sorted-map
         "claim_id" (get entity "claim_id")
         "current_state" (get entity "state")
         "validation_timestamp" (get entity "updated_at"))]
     
     [stage-ephemeral (entity parsed accessors)
       ;; Store temporary validation data if needed
       (vector)]
     
     [stage-durable (entity parsed accessors)
       ;; Persist any validation results or metadata
       (sorted-map
         "custom_validation_passed" true
         "custom_validation_timestamp" (get parsed "validation_timestamp"))]
     
     [create-events (entity parsed accessors)
       ;; Optionally emit events (e.g., audit log, notification, etc.)
       ;; For now, no events - just a pass-through state
       (cc:infof (sorted-map) "yep we passed through")
       (vector)])
    
    (mk-state-handler
      :next            (or next-state "CUSTOM_VALIDATION_COMPLETE")
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events
      :after-storage-hook after-storage-hook)))

;; Combined state spec for the entire process
;; Merges all workflow state specs and overrides specific handlers for chaining
;; Custom states can be inserted anywhere in the chain
(set 'state-spec-claim
     (merge-state-specs
       ;; Base workflow specs (merged in order)
       state-spec-wf1
       state-spec-wf2
      (sorted-map
         "CUSTOM_VALIDATION_STATE" (custom-validation-state-handler))
       state-spec-wf3
       state-spec-wf4  ;; workflow-4-edit (includes WAITING_FOR_SIGNATURE and CONTRACT_SIGNED states)
       state-spec-wf5
       ;; Custom states (inserted between workflows or within workflows)
  
       ;; Overrides for unified process chaining using after-storage hooks
       ;; Workflows transition to their DONE states, then hooks chain to the next workflow
       (sorted-map
         ;; WF1: chain to WF2 via hook
         "WF1_CLAIM_TEAMS_THREAD_CREATED"           (wf1-teams-thread-created-state-handler 
                                                      "WF2_CLAIM_STATE_INIT" 
                                                      (lambda (entity) 
                                                        (let* ([claim-id (get entity "claim_id")]) 
                                                          (cc:infof (sorted-map "claim_id" claim-id) "WF1 completed - chaining to WF2 via after-storage hook") 
                                                          (let* ([updated-entity (assoc entity "state" "WF2_CLAIM_STATE_INIT")]) 
                                                            (claim-manager 'put updated-entity) 
                                                            (trigger-connector-object claim-manager claim-id (sorted-map "claim_id" claim-id))))))

         "WF2_CLAIM_STATE_GUIDEWIRE_APPROVED"      (wf2-claim-guidewire-approved-state-handler
                                                      "CUSTOM_VALIDATION_STATE"
                                                      (lambda (entity)
                                                        (let* ([claim-id (get entity "claim_id")])
                                                          (cc:infof
                                                            (sorted-map "claim_id" claim-id)
                                                            "WF2 completed - chaining to CUSTOM_VALIDATION_STATE via after-storage hook")
                                                          ;; Update entity state to CUSTOM_VALIDATION_STATE, then trigger
                                                          (let* ([updated-entity (assoc entity "state" "CUSTOM_VALIDATION_STATE")])
                                                            (claim-manager 'put updated-entity)
                                                            (trigger-connector-object 
                                                              claim-manager 
                                                              claim-id 
                                                              (sorted-map "claim_id" claim-id))))))
         ;; CUSTOM_VALIDATION_STATE: hook chains to WF3
         "CUSTOM_VALIDATION_STATE"                 (custom-validation-state-handler 
                                                      "WF3_CLAIM_STATE_INVOICE_INIT"
                                                      (lambda (entity)
                                                        (let* ([claim-id (get entity "claim_id")])
                                                          (cc:infof
                                                            (sorted-map "claim_id" claim-id)
                                                            "CUSTOM_VALIDATION_STATE completed - chaining to WF3 via after-storage hook")
                                                          ;; Update entity state to WF3's initial state, then trigger
                                                          (let* ([updated-entity (assoc entity "state" "WF3_CLAIM_STATE_INVOICE_INIT")])
                                                            (claim-manager 'put updated-entity)
                                                            (trigger-connector-object 
                                                              claim-manager 
                                                              claim-id 
                                                              (sorted-map "claim_id" claim-id))))))
         ;; WF3: transition directly to WF4 init via hook
         "WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED" (wf3-invoice-email-dispatched-state-handler 
                                                       "WF4_CLAIM_STATE_INIT"
                                                       (lambda (entity)
                                                         (let* ([claim-id (get entity "claim_id")])
                                                           (cc:infof
                                                             (sorted-map "claim_id" claim-id)
                                                             "WF3 completed - chaining to WF4 via after-storage hook")
                                                           ;; Update entity state to WF4's initial state, then trigger
                                                           (let* ([updated-entity (assoc entity "state" "WF4_CLAIM_STATE_INIT")])
                                                             (claim-manager 'put updated-entity)
                                                             (trigger-connector-object 
                                                               claim-manager 
                                                               claim-id 
                                                               (sorted-map "claim_id" claim-id))))))
         ;; WF4: transition directly to WF5 init via hook
         "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED" (wf4-servicenow-incident-created-state-handler 
                                                         "WF5_CLAIM_STATE_INIT"
                                                         (lambda (entity)
                                                           (let* ([claim-id (get entity "claim_id")])
                                                             (cc:infof
                                                               (sorted-map "claim_id" claim-id)
                                                               "WF4 completed - chaining to WF5 via after-storage hook")
                                                             ;; Update entity state to WF5's initial state, then trigger
                                                             (let* ([updated-entity (assoc entity "state" "WF5_CLAIM_STATE_INIT")])
                                                               (claim-manager 'put updated-entity)
                                                               (trigger-connector-object 
                                                                 claim-manager 
                                                                 claim-id 
                                                                 (sorted-map "claim_id" claim-id)))))))))

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


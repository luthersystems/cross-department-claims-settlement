(in-package 'sandbox)

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

;; Combined state spec for the entire process
;; Merges all workflow state specs and overrides specific handlers for chaining
(set 'state-spec-claim
     (merge-state-specs
       ;; Base workflow specs (merged in order)
       state-spec-wf1
       state-spec-wf2
       state-spec-wf3
       state-spec-wf4
       state-spec-wf5
       ;; Overrides for unified process chaining
       (sorted-map
         "WF1_CLAIM_TEAMS_THREAD_CREATED"           (wf1-teams-thread-created-state-handler "WF2_CLAIM_STATE_INIT")
         "WF2_CLAIM_STATE_GUIDEWIRE_APPROVED"      (wf2-claim-guidewire-approved-state-handler "WF3_CLAIM_STATE_INVOICE_INIT")
         "WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED" (wf3-invoice-email-dispatched-state-handler "WF4_CLAIM_STATE_INIT")
         "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED" (wf4-servicenow-incident-created-state-handler "WF5_CLAIM_STATE_INIT"))))

;; Unified claim manager for the entire process
;; State transitions between workflows are handled directly by handlers (via :immediate-next and next-state)
;; Completion logging is handled by notify-workflow-completion-by-entity-name in the state machine
(set 'claim-manager
     (singleton (mk-entity-manager
                 "claim"                    ;; entity kind
                 "claim_id"                 ;; primary key field
                 "WF1_CLAIM_STATE_NEW"      ;; initial state (start with WF1)
                 state-spec-claim)))

(register-connector-factory claim-manager)

;; Register workflow for easy invocation
(register-workflow "process" claim-manager)


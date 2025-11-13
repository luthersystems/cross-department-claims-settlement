(in-package 'sandbox)

(use-package 'connector)


;; -----------------------------------------------------------------------------
;; Register WF1
;; -----------------------------------------------------------------------------

(set 'state-spec-wf1
  (sorted-map
    "WF1_CLAIM_STATE_NEW"                      (wf1-claim-init-state-handler)
    "WF1_CLAIM_STATE_ORACLE_DETAILS_RETRIEVED" (wf1-claim-oracle-details-retrieved-state-handler)
    "WF1_CLAIM_STATE_EQUIFAX_VERIFIED"         (wf1-claim-equifax-verified-state-handler)
    "WF1_CLAIM_TEAMS_THREAD_CREATED"           (wf1-teams-thread-created-state-handler)
    "WF1_CLAIM_STATE_DONE"                     (wf1-claim-done-state-handler)))

;; -----------------------------------------------------------------------------
;; Register WF2
;; -----------------------------------------------------------------------------

(set 'state-spec-wf2
  (sorted-map
    "WF2_CLAIM_STATE_INIT"                  (wf2-claim-init-state-handler)
    "WF2_CLAIM_STATE_GUIDEWIRE_SNAPSHOTTED" (wf2-claim-guidewire-snapshotted-state-handler)
    "WF2_CLAIM_STATE_MYSQL_VALIDATED"       (wf2-claim-mysql-validated-state-handler)
    "WF2_CLAIM_STATE_SP_DOCS_COLLECTED"     (wf2-claim-sp-docs-collected-state-handler)
    "WF2_CLAIM_STATE_GUIDEWIRE_APPROVED"    (wf2-claim-guidewire-approved-state-handler)
    "WF2_CLAIM_STATE_DONE"                  (wf2-claim-done-state-handler)))

;; -----------------------------------------------------------------------------
;; Register WF3
;; -----------------------------------------------------------------------------

(set 'state-spec-wf3
  (sorted-map
    "WF3_CLAIM_STATE_INVOICE_INIT"                  (wf3-invoice-init-state-handler)
    "WF3_CLAIM_STATE_INVOICE_ESIG_CREATED"          (wf3-invoice-esig-created-state-handler)
    "WF3_CLAIM_STATE_INVOICE_SF_SYNCED"             (wf3-invoice-sf-synced-state-handler)
    "WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED"      (wf3-invoice-email-dispatched-state-handler)
    "WF3_CLAIM_STATE_DONE"                          (wf3-claim-done-state-handler)))

;; -----------------------------------------------------------------------------
;; Register WF4
;; -----------------------------------------------------------------------------

(set 'state-spec-wf4
  (sorted-map
    "WF4_CLAIM_STATE_INIT"                          (wf4-claim-init-state-handler)
    "WF4_CLAIM_STATE_ZOHO_INVOICE_CREATED"          (wf4-zoho-invoice-created-state-handler)
    "WF4_CLAIM_STATE_SHAREPOINT_DOC_RETRIEVED"      (wf4-sharepoint-doc-retrieved-state-handler)
    "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED"   (wf4-servicenow-incident-created-state-handler)
    "WF4_CLAIM_STATE_DONE"                          (wf4-claim-done-state-handler)))

;; -----------------------------------------------------------------------------
;; Register WF5
;; -----------------------------------------------------------------------------

(set 'state-spec-wf5
  (sorted-map
    "WF5_CLAIM_STATE_INIT"              (wf5-claim-init-state-handler)
    "WF5_CLAIM_STATE_AWAITING_APPROVAL" (wf5-claim-awaiting-approval-handler)
    "WF5_CLAIM_STATE_SAP_PAID"          (wf5-claim-sap-paid-handler)
    "WF5_CLAIM_STATE_DONE"              (wf5-claim-done-state-handler)))

;; Completion hook for WF1: trigger WF2
(set 'wf1-completion-hook
     (lambda (entity-name entity state parsed)
       (let* ([wf2-inputs (wf1-build-wf2-inputs entity parsed)]
              [result (invoke-workflow claim-manager-wf2 wf2-inputs)])
         (cc:infof (sorted-map
                     "wf1_claim_id" (get entity "claim_id")
                     "wf2_claim_id" (get result "claim_id")
                     "wf2_state" (get result "state"))
                   "WF1 chained to WF2"))))

;; Completion hook for WF2: trigger WF3
(set 'wf2-completion-hook
     (lambda (entity-name entity state parsed)
       (cc:infof (sorted-map "entity-name" entity-name
                              "claim_id" (get entity "claim_id")
                              "state" state)
                 "WF2 flow complete")
       (let* ([wf3-inputs (wf2-build-wf3-inputs entity parsed)]
              [result (invoke-workflow claim-manager-wf3 wf3-inputs)])
         (cc:infof (sorted-map
                     "wf2_claim_id" (get entity "claim_id")
                     "wf3_claim_id" (get result "claim_id")
                     "wf3_state" (get result "state"))
                   "WF2 chained to WF3"))))


(set 'wf3-completion-hook
     (lambda (entity-name entity state parsed)
       (cc:infof (sorted-map "entity-name" entity-name
                              "claim_id" (get entity "claim_id")
                              "state" state)
                 "WF3 flow complete")
       (let* ([wf4-inputs (wf3-build-wf4-inputs entity parsed)]
              [result (invoke-workflow claim-manager-wf4 wf4-inputs)])
         (cc:infof (sorted-map
                     "wf3_claim_id" (get entity "claim_id")
                     "wf4_claim_id" (get result "claim_id")
                     "wf4_state" (get result "state"))
                   "WF3 chained to WF4"))))

(set 'wf4-completion-hook
     (lambda (entity-name entity state parsed)
       (cc:infof (sorted-map "entity-name" entity-name
                              "claim_id" (get entity "claim_id")
                              "state" state)
                 "WF4 flow complete")
       (let* ([wf5-inputs (wf4-build-wf5-inputs entity parsed)]
              [result (invoke-workflow claim-manager-wf5 wf5-inputs)])
         (cc:infof (sorted-map
                     "wf4_claim_id" (get entity "claim_id")
                     "wf5_claim_id" (get result "claim_id")
                     "wf5_state" (get result "state"))
                   "WF4 chained to WF5"))))

(set 'wf5-completion-hook
     (lambda (entity-name entity state parsed)
       (cc:infof (sorted-map "entity-name" entity-name
                              "claim_id" (get entity "claim_id")
                              "state" state)
                 "WF5 flow complete")))

;; -----------------------------------------------------------------------------
;; Unified Process Manager: All workflows combined
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

;; Combined state spec for the entire process (WF1 → WF2 → WF3 → WF4 → WF5)
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

;; Completion hook for unified process: logs completion of workflow stages
;; State transitions are handled directly by handlers (via :next parameter)
;; This hook is called for logging/monitoring purposes
(set 'claim-process-completion-hook
     (lambda (entity-name entity state parsed)
       ;; Guard: only process for unified "claim" entity
       (when (equal? entity-name "claim")
         (let* ([claim-id (get entity "claim_id")]
                [current-state (get entity "state")])
           (cond
             ;; WF1 complete
             ((equal? state "WF1_CLAIM_STATE_DONE")
              (cc:infof (sorted-map "claim_id" claim-id "state" current-state)
                        "WF1 complete, transitioning to WF2"))
             ;; WF2 complete
             ((equal? state "WF2_CLAIM_STATE_DONE")
              (cc:infof (sorted-map "claim_id" claim-id "state" current-state)
                        "WF2 complete, transitioning to WF3"))
             ;; WF3 complete
             ((equal? state "WF3_CLAIM_STATE_DONE")
              (cc:infof (sorted-map "claim_id" claim-id "state" current-state)
                        "WF3 complete, transitioning to WF4"))
             ;; WF4 complete
             ((equal? state "WF4_CLAIM_STATE_DONE")
              (cc:infof (sorted-map "claim_id" claim-id "state" current-state)
                        "WF4 complete, transitioning to WF5"))
             ;; WF5 complete → entire process finished
             ((equal? state "WF5_CLAIM_STATE_DONE")
              (cc:infof (sorted-map "claim_id" claim-id "state" current-state)
                        "Complete claim process finished (WF1 → WF2 → WF3 → WF4 → WF5)"))
             (:else
              (cc:infof (sorted-map "claim_id" claim-id "state" current-state)
                        "Unified process reached state: {}" state)))))))

;; Unified claim manager for the entire process
;; State transitions between workflows are handled by done handlers (via :next parameter)
;; Completion hook is called for logging/monitoring when reaching DONE states
(set 'claim-manager
     (singleton (mk-entity-manager
                 "claim"                    ;; entity kind
                 "claim_id"                 ;; primary key field
                 "WF1_CLAIM_STATE_NEW"      ;; initial state (start with WF1)
                 state-spec-claim
                 "WF5_CLAIM_STATE_DONE"     ;; final state (end with WF5)
                 claim-process-completion-hook)))

(register-connector-factory claim-manager)

;; Register workflow for easy invocation
(register-workflow "process" claim-manager)

;; Define WF3 manager first so it's available when WF2/F1 completion hooks reference it
(set 'claim-manager-wf3
     (singleton (mk-entity-manager
                  "claim_wf3"            ;; entity kind
                  "claim_id"         ;; primary key field
                  "WF3_CLAIM_STATE_INVOICE_INIT" ;; initial state
                  state-spec-wf3
                  "WF3_CLAIM_STATE_DONE"  ;; final state - triggers completion hooks
                  wf3-completion-hook)))

(register-connector-factory claim-manager-wf3)

;; Register workflow for easy invocation
(register-workflow "wf3" claim-manager-wf3)

;; Register completion listener for WF3 (invoice workflow)
;; This will log "invoice workflow completed!" when WF3 finishes
(register-workflow-completion-listener
  "wf3"
  (lambda (workflow-name entity)
    (cc:infof
      (sorted-map
        "workflow" workflow-name
        "claim_id" (get entity "claim_id"))
      "Invoice workflow completed!")))

;; Define WF2 manager after WF3 so claim-manager-wf3 is available in the completion hook
(set 'claim-manager-wf2
     (singleton (mk-entity-manager
                  "claim_wf2"            ;; MUST BE UNIQUE ACROSS WORKFLOW
                  "claim_id"         ;; primary key field
                  "WF2_CLAIM_STATE_INIT" ;; initial state
                  state-spec-wf2
                  "WF2_CLAIM_STATE_DONE"  ;; final state - triggers completion hooks
                  wf2-completion-hook)))

(register-connector-factory claim-manager-wf2)

;; Register workflow for easy invocation
(register-workflow "wf2" claim-manager-wf2)

;; Define WF1 manager after WF2 so chaining can reference the WF2 manager instance
(set 'claim-manager-wf1
     (singleton (mk-entity-manager
                  "claim_wf1"
                  "claim_id"
                  "WF1_CLAIM_STATE_NEW"
                  state-spec-wf1
                  "WF1_CLAIM_STATE_DONE"
                  wf1-completion-hook)))

(register-connector-factory claim-manager-wf1)

(register-workflow "wf1" claim-manager-wf1)

(register-workflow-completion-listener
  "wf1"
  (lambda (workflow-name entity)
    (cc:infof
      (sorted-map
        "workflow" workflow-name
        "claim_id" (get entity "claim_id"))
      "Oracle workflow completed!")))

;; Define WF4 manager last to absorb chained traffic from WF3
(set 'claim-manager-wf4
     (singleton (mk-entity-manager
                  "claim_wf4"
                  "claim_id"
                  "WF4_CLAIM_STATE_INIT"
                  state-spec-wf4
                  "WF4_CLAIM_STATE_DONE"
                  wf4-completion-hook)))

(register-connector-factory claim-manager-wf4)
(register-workflow "wf4" claim-manager-wf4)

(register-workflow-completion-listener
  "wf4"
  (lambda (workflow-name entity)
    (cc:infof
      (sorted-map
        "workflow" workflow-name
        "claim_id" (get entity "claim_id"))
      "Zoho/ServiceNow workflow completed!")))

;; Define WF5 manager to absorb chained traffic from WF4
(set 'claim-manager-wf5
     (singleton (mk-entity-manager
                  "claim_wf5"
                  "claim_id"
                  "WF5_CLAIM_STATE_INIT"
                  state-spec-wf5
                  "WF5_CLAIM_STATE_DONE"
                  wf5-completion-hook)))

(register-connector-factory claim-manager-wf5)
(register-workflow "wf5" claim-manager-wf5)

(register-workflow-completion-listener
  "wf5"
  (lambda (workflow-name entity)
    (cc:infof
      (sorted-map
        "workflow" workflow-name
        "claim_id" (get entity "claim_id"))
      "SAP/NetSuite workflow completed!")))
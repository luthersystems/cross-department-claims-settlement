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

;; Define WF3 manager
(set 'claim-manager-wf3
     (singleton (mk-entity-manager
                  "claim_wf3"            ;; entity kind
                  "claim_id"         ;; primary key field
                  "WF3_CLAIM_STATE_INVOICE_INIT" ;; initial state
                  state-spec-wf3)))

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

;; Define WF2 manager
(set 'claim-manager-wf2
     (singleton (mk-entity-manager
                  "claim_wf2"            ;; MUST BE UNIQUE ACROSS WORKFLOW
                  "claim_id"         ;; primary key field
                  "WF2_CLAIM_STATE_INIT" ;; initial state
                  state-spec-wf2)))

(register-connector-factory claim-manager-wf2)

;; Register workflow for easy invocation
(register-workflow "wf2" claim-manager-wf2)

;; Define WF1 manager
(set 'claim-manager-wf1
     (singleton (mk-entity-manager
                  "claim_wf1"
                  "claim_id"
                  "WF1_CLAIM_STATE_NEW"
                  state-spec-wf1)))

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

;; Define WF4 manager
(set 'claim-manager-wf4
     (singleton (mk-entity-manager
                  "claim_wf4"
                  "claim_id"
                  "WF4_CLAIM_STATE_INIT"
                  state-spec-wf4)))

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

;; Define WF5 manager
(set 'claim-manager-wf5
     (singleton (mk-entity-manager
                  "claim_wf5"
                  "claim_id"
                  "WF5_CLAIM_STATE_INIT"
                  state-spec-wf5)))

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
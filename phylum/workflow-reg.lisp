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

;; Completion hook for WF1: optionally trigger WF2
(set 'wf1-completion-hook
     (lambda (entity-name entity state parsed)
       (cc:infof (sorted-map "entity-name" entity-name
                              "claim_id" (get entity "claim_id")
                              "state" state)
                 "WF1 flow complete")
       (let* ([chain-enabled (wf1-should-chain? entity)])
         (if (not chain-enabled)
             (cc:infof (sorted-map "entity-name" entity-name
                                    "claim_id" (get entity "claim_id"))
                       "WF1 chaining disabled; skipping WF2 trigger")
             (let* ([wf2-inputs (wf1-build-wf2-inputs entity parsed)]
                    [result (invoke-workflow claim-manager-wf2 wf2-inputs)])
               (cc:infof (sorted-map
                           "wf1_claim_id" (get entity "claim_id")
                           "wf2_claim_id" (get result "claim_id")
                           "wf2_state" (get result "state"))
                         "WF1 chained to WF2"))))))

;; Completion hook for WF2: decide whether to chain and trigger WF3 as needed.
(set 'wf2-completion-hook
     (lambda (entity-name entity state parsed)
       (cc:infof (sorted-map "entity-name" entity-name
                              "claim_id" (get entity "claim_id")
                              "state" state)
                 "WF2 flow complete")
       (let* ([chain-enabled (wf2-should-chain? entity)])
         (if (not chain-enabled)
             (cc:infof (sorted-map "entity-name" entity-name
                                    "claim_id" (get entity "claim_id"))
                       "WF2 chaining disabled; skipping WF3 trigger")
             (let* ([wf3-inputs (wf2-build-wf3-inputs entity parsed)]
                    [result (invoke-workflow claim-manager-wf3 wf3-inputs)])
               (cc:infof (sorted-map
                           "wf2_claim_id" (get entity "claim_id")
                           "wf3_claim_id" (get result "claim_id")
                           "wf3_state" (get result "state"))
                         "WF2 chained to WF3"))))))


(set 'wf3-completion-hook
     (lambda (entity-name entity state parsed)
       (cc:infof (sorted-map "entity-name" entity-name
                              "claim_id" (get entity "claim_id")
                              "state" state)
                 "WF3 flow complete")
       (let* ([chain-enabled (wf3-should-chain? entity)])
         (if (not chain-enabled)
             (cc:infof (sorted-map "entity-name" entity-name
                                    "claim_id" (get entity "claim_id"))
                       "WF3 chaining disabled; skipping WF4 trigger")
             (let* ([wf4-inputs (wf3-build-wf4-inputs entity parsed)]
                    [result (invoke-workflow claim-manager-wf4 wf4-inputs)])
               (cc:infof (sorted-map
                           "wf3_claim_id" (get entity "claim_id")
                           "wf4_claim_id" (get result "claim_id")
                           "wf4_state" (get result "state"))
                         "WF3 chained to WF4"))))))

(set 'wf4-completion-hook
     (lambda (entity-name entity state parsed)
       (cc:infof (sorted-map "entity-name" entity-name
                              "claim_id" (get entity "claim_id")
                              "state" state)
                 "WF4 flow complete")
       (let* ([chain-enabled (wf4-should-chain? entity)])
         (if (not chain-enabled)
             (cc:infof (sorted-map "entity-name" entity-name
                                    "claim_id" (get entity "claim_id"))
                       "WF4 chaining disabled; skipping WF5 trigger")
             (let* ([wf5-inputs (wf4-build-wf5-inputs entity parsed)]
                    [result (invoke-workflow claim-manager-wf5 wf5-inputs)])
               (cc:infof (sorted-map
                           "wf4_claim_id" (get entity "claim_id")
                           "wf5_claim_id" (get result "claim_id")
                           "wf5_state" (get result "state"))
                         "WF4 chained to WF5"))))))

(set 'wf5-completion-hook
     (lambda (entity-name entity state parsed)
       (cc:infof (sorted-map "entity-name" entity-name
                              "claim_id" (get entity "claim_id")
                              "state" state)
                 "WF5 flow complete")))

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
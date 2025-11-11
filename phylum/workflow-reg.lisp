(in-package 'sandbox)

(use-package 'connector)


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
    "WF2_CLAIM_STATE_DONE"                  (wf2-claim-done-state-handler)
  ))

(set 'state-spec-wf3
  (sorted-map
    "WF3_CLAIM_STATE_INVOICE_INIT"                  (wf3-invoice-init-state-handler)
    "WF3_CLAIM_STATE_INVOICE_ESIG_CREATED"          (wf3-invoice-esig-created-state-handler)
    "WF3_CLAIM_STATE_INVOICE_SF_SYNCED"             (wf3-invoice-sf-synced-state-handler)
    "WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED"      (wf3-invoice-email-dispatched-state-handler)
    "WF3_CLAIM_STATE_DONE"                          (wf3-claim-done-state-handler)
  ))

;; Define WF3 manager first so it's available when WF2 completion hook references it
(set 'claim-manager-wf3
     (singleton (mk-entity-manager
                  "claim_wf3"            ;; entity kind
                  "claim_id"         ;; primary key field
                  "WF3_CLAIM_STATE_INVOICE_INIT" ;; initial state
                  state-spec-wf3
                  "WF3_CLAIM_STATE_DONE"  ;; final state - triggers completion hooks
                  (lambda (entity-name entity state parsed)
                    (cc:infof (sorted-map "entity-name" entity-name "claim_id" (get entity "claim_id") "state" state)
                              "Flow complete!")))))

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
                  (lambda (entity-name entity state parsed)
                    (cc:infof (sorted-map "entity-name" entity-name "claim_id" (get entity "claim_id") "state" state)
                              "Flow complete!")
                    ;; Trigger workflow 3 after WF2 completes
                    (let* ([wf3-inputs (sorted-map
                                         "claim_id"        "CLM-4567"
                                         "invoice_amount"  "20000.00"
                                         "signer_name"     "Jack Clarke"
                                         "signer_email"    "jack.clarke@luthersystems.com"
                                         "originator_name" "Acme Insurance Ltd."
                                         "recipient_name"  "BlueRiver Underwriting Partners"
                                         "issue_date"      "2025-11-05")]
                           [result (invoke-workflow claim-manager-wf3 wf3-inputs)])
                      (cc:infof (sorted-map "wf3_claim_id" (get result "claim_id") "wf3_state" (get result "state"))
                                "Workflow 3 triggered from WF2 completion"))))))

(register-connector-factory claim-manager-wf2)

;; Register workflow for easy invocation
(register-workflow "wf2" claim-manager-wf2)

; AS IS: an event is raised for a state transition. The connetorhub routes the
; event to the correct manager based on the event type. When we create the event
; we register a request ID. The connectorhub includes this request ID in its
; response When we receive the response, we look up the request ID. 

;wondering whetehr we should "append to state machine" or have multiple state machines for each workflow
(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; WF4 State Specification & Manager Registration
;; -----------------------------------------------------------------------------

(set 'state-spec-wf4
  (sorted-map
    "WF4_CLAIM_STATE_INIT"                          (wf4-claim-init-state-handler)
    "WF4_CLAIM_STATE_ZOHO_INVOICE_CREATED"          (wf4-zoho-invoice-created-state-handler)
    "WF4_CLAIM_STATE_SHAREPOINT_DOC_RETRIEVED"      (wf4-sharepoint-doc-retrieved-state-handler)
    "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED"   (wf4-servicenow-incident-created-state-handler)
    "WF4_CLAIM_STATE_DONE"                          (wf4-claim-done-state-handler)))

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


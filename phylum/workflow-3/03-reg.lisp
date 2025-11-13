(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; WF3 State Specification & Manager Registration
;; -----------------------------------------------------------------------------

(set 'state-spec-wf3
  (sorted-map
    "WF3_CLAIM_STATE_INVOICE_INIT"                  (wf3-invoice-init-state-handler)
    "WF3_CLAIM_STATE_INVOICE_ESIG_CREATED"          (wf3-invoice-esig-created-state-handler)
    "WF3_CLAIM_STATE_INVOICE_SF_SYNCED"             (wf3-invoice-sf-synced-state-handler)
    "WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED"      (wf3-invoice-email-dispatched-state-handler)
    "WF3_CLAIM_STATE_DONE"                          (wf3-claim-done-state-handler)))

(set 'claim-manager-wf3
     (singleton (mk-entity-manager
                 "claim_wf3"
                 "claim_id"
                 "WF3_CLAIM_STATE_INVOICE_INIT"
                 state-spec-wf3)))

(register-connector-factory claim-manager-wf3)
(register-workflow "wf3" claim-manager-wf3)

(register-workflow-completion-listener
  "wf3"
  (lambda (workflow-name entity)
    (cc:infof
      (sorted-map
        "workflow" workflow-name
        "claim_id" (get entity "claim_id"))
      "Invoice workflow completed!")))


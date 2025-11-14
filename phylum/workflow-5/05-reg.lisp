(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; WF5 State Specification & Manager Registration
;; -----------------------------------------------------------------------------

(set 'state-spec-wf5
  (sorted-map
    "WF5_CLAIM_STATE_INIT"              (wf5-claim-init-state-handler)
    "WF5_CLAIM_STATE_AWAITING_APPROVAL" (wf5-claim-awaiting-approval-handler)
    "WF5_CLAIM_STATE_D365FO_PAID"      (wf5-claim-d365fo-paid-handler)
    "WF5_CLAIM_STATE_SAP_PAID"         (wf5-claim-sap-paid-handler)
    "WF5_CLAIM_STATE_DONE"             (wf5-claim-done-state-handler)))

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
      "D365FO payment journal + SAP HANA recording workflow completed!")))


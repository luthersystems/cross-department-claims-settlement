(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; WF1 State Specification & Manager Registration
;; -----------------------------------------------------------------------------

(set 'state-spec-wf1
  (sorted-map
    "WF1_CLAIM_STATE_NEW"                      (wf1-claim-init-state-handler)
    "WF1_CLAIM_STATE_ORACLE_DETAILS_RETRIEVED" (wf1-claim-oracle-details-retrieved-state-handler)
    "WF1_CLAIM_STATE_EQUIFAX_VERIFIED"         (wf1-claim-equifax-verified-state-handler)
    "WF1_CLAIM_TEAMS_THREAD_CREATED"           (wf1-teams-thread-created-state-handler)
    "WF1_CLAIM_STATE_DONE"                     (wf1-claim-done-state-handler)))

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


(in-package 'sandbox)

;; -----------------------------------------------------------------------------
;; Create the state machine for Cross-Department Claim → Settlement
;; -----------------------------------------------------------------------------

(set 'state-spec
  (sorted-map
    "WF1_CLAIM_STATE_NEW"                      (wf1-claim-init-state-handler)
    "WF1_CLAIM_STATE_ORACLE_DETAILS_RETRIEVED" (wf1-claim-oracle-details-retrieved-state-handler)
    "WF1_CLAIM_STATE_EQUIFAX_VERIFIED"         (wf1-claim-equifax-verified-state-handler)
    "WF1_CLAIM_STATE_DONE"                     (wf1-claim-done-state-handler)
  ))

;; -----------------------------------------------------------------------------
;; Build the claims connector from the generic factory
;; -----------------------------------------------------------------------------

(set 'claim-manager
     (singleton (mk-entity-manager
                  "claim_wf1"
                  "claim_id"
                  "WF1_CLAIM_STATE_NEW"
                  state-spec)))

(register-connector-factory claim-manager)

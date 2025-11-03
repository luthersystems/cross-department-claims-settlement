(in-package 'sandbox)

;; -----------------------------------------------------------------------------
;; Create the state machine for Cross-Department Claim → Settlement
;; -----------------------------------------------------------------------------

(set 'state-spec
  (sorted-map
    "CLAIM_STATE_NEW"                           (claim-init-state-handler)
    "CLAIM_STATE_ORACLE_DETAILS_RETRIEVED"      (claim-oracle-details-retrieved-state-handler)
    "CLAIM_STATE_EQUIFAX_VERIFIED"              (claim-equifax-verified-state-handler)
    "CLAIM_STATE_DONE"                          (claim-done-state-handler)
  ))

;; -----------------------------------------------------------------------------
;; Build the claims connector from the generic factory
;; -----------------------------------------------------------------------------

(set 'claim-manager
     (singleton (mk-entity-manager
                  "claim"            ;; entity kind
                  "claim_id"         ;; primary key field
                  "CLAIM_STATE_NEW"  ;; initial state
                  state-spec)))

(register-connector-factory claim-manager)

(in-package 'sandbox)

;; -----------------------------------------------------------------------------
;; Create the state machine for Cross-Department Claim → Settlement
;; -----------------------------------------------------------------------------

(set 'state-spec
  (sorted-map
    "CLAIM_STATE_NEW"                   (claim-1-init-state-handler)
    "CLAIM_STATE_MYSQL_RETRIEVED"      (claim-oracle-retrieved-state-handler)
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

;; Helper to create a new claim connector object via factory
(defun create-claim ()
  (new-connector-object claim-manager))

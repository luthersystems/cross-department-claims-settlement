(in-package 'sandbox)

(use-package 'connector)

;; -----------------------------------------------------------------------------
;; Create the state machine for Cross-Department Claim → Settlement
;; -----------------------------------------------------------------------------

(set 'state-spec
  (sorted-map
    "CLAIM_STATE_INIT"                  (claim-init-state-handler)
    "CLAIM_STATE_BASWARE_INVOICED"      (claim-basware-invoiced-state-handler)
    "CLAIM_STATE_SF_SYNCED"             (claim-sf-synced-state-handler)
    "CLAIM_STATE_SMTP_DISPATCHED"       (claim-smtp-dispatched-state-handler)
    ;; Terminal state is CLAIM_STATE_DONE (no handler needed)
  ))

;; -----------------------------------------------------------------------------
;; Build the claims connector from the generic factory
;; -----------------------------------------------------------------------------

(set 'claim-manager
     (singleton (mk-entity-manager
                  "claim"            ;; entity kind
                  "claim_id"         ;; primary key field
                  "CLAIM_STATE_INIT" ;; initial state
                  state-spec)))

(register-connector-factory claim-manager)

;; Helper to create a new claim connector object via factory
(defun create-claim ()
  (new-connector-object claim-manager))

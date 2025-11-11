(in-package 'sandbox)

(use-package 'connector)

;; -----------------------------------------------------------------------------
;; Create the state machine for Cross-Department Claim → Settlement
;; -----------------------------------------------------------------------------

(set 'state-spec-wf3
  (sorted-map
    "CLAIM_STATE_INVOICE_INIT"                  (invoice-init-state-handler)
    "CLAIM_STATE_INVOICE_ESIG_CREATED"          (invoice-esig-created-state-handler)
    "CLAIM_STATE_INVOICE_SF_SYNCED"             (invoice-sf-synced-state-handler)
    "CLAIM_STATE_INVOICE_EMAIL_DISPATCHED"      (invoice-email-dispatched-state-handler)
    "CLAIM_STATE_DONE"                          (claim-done-state-handler)

  ))


;; -----------------------------------------------------------------------------
;; Build the claims connector from the generic factory
;; -----------------------------------------------------------------------------

(set 'claim-manager-wf3
     (singleton (mk-entity-manager
                  "claim"            ;; entity kind
                  "claim_id"         ;; primary key field
                  "CLAIM_STATE_INVOICE_INIT" ;; initial state
                  state-spec-wf3)))

(register-connector-factory claim-manager-wf3)

;; Helper to create a new claim connector object via factory
(defun create-claim-wf3 ()
  (new-connector-object claim-manager-wf3))

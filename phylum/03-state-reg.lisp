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

; register the clam manager for workflow 3 againt the name claim_wf3
(set 'claim-manager-wf3
     (singleton (mk-entity-manager
                  "claim_wf3"            ;; entity kind
                  "claim_id"         ;; primary key field
                  "CLAIM_STATE_INVOICE_INIT" ;; initial state
                  state-spec-wf3)))

(register-connector-factory claim-manager-wf3)
(cc:infof (sorted-map "claim-manager-wf3" claim-manager-wf3) "claim-manager-wf3 registered")
(cc:infof (sorted-map "claim-manager-wf2" claim-manager-wf2) "claim-manager-wf2 registered")


;; Helper to create a new claim connector object via factory
(defun create-claim-wf3 ()
  (new-connector-object claim-manager-wf3))

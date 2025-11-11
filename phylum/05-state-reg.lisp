; (in-package 'sandbox)

; (use-package 'connector)

; ;; -----------------------------------------------------------------------------
; ;; Register WF5 (SAP payment acknowledgement)
; ;; -----------------------------------------------------------------------------

; (set 'state-spec-wf5
;   (sorted-map
;     "WF5_CLAIM_STATE_INIT"              (wf5-claim-init-state-handler)
;     "WF5_CLAIM_STATE_AWAITING_APPROVAL" (wf5-claim-awaiting-approval-handler)
;     "WF5_CLAIM_STATE_SAP_PAID"          (wf5-claim-sap-paid-handler)
;     "WF5_CLAIM_STATE_DONE"              (wf5-claim-done-state-handler)))

; (set 'claim-manager-wf5
;      (singleton (mk-entity-manager
;                   "claim_wf5"
;                   "claim_id"
;                   "WF5_CLAIM_STATE_INIT"
;                   state-spec-wf5
;                   "WF5_CLAIM_STATE_DONE")))

; (register-connector-factory claim-manager-wf5)

; ;; Helper to create a new claim connector object via factory
; (defun create-claim ()
;   (new-connector-object claim-manager))

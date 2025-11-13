(in-package 'sandbox)

;; -----------------------------------------------------------------------------
;; WF2 State Specification & Manager Registration
;; -----------------------------------------------------------------------------

(set 'state-spec-wf2
  (sorted-map
    "WF2_CLAIM_STATE_INIT"                  (wf2-claim-init-state-handler)
    "WF2_CLAIM_STATE_GUIDEWIRE_SNAPSHOTTED" (wf2-claim-guidewire-snapshotted-state-handler)
    "WF2_CLAIM_STATE_MYSQL_VALIDATED"       (wf2-claim-mysql-validated-state-handler)
    "WF2_CLAIM_STATE_SP_DOCS_COLLECTED"     (wf2-claim-sp-docs-collected-state-handler)
    "WF2_CLAIM_STATE_GUIDEWIRE_APPROVED"    (wf2-claim-guidewire-approved-state-handler)
    "WF2_CLAIM_STATE_DONE"                  (wf2-claim-done-state-handler)))

(set 'claim-manager-wf2
     (singleton (mk-entity-manager
                 "claim_wf2"
                 "claim_id"
                 "WF2_CLAIM_STATE_INIT"
                 state-spec-wf2)))

(register-connector-factory claim-manager-wf2)
(register-workflow "wf2" claim-manager-wf2)


(in-package 'sandbox)

(use-package 'connector)

;; -----------------------------------------------------------------------------
;; Create the state machine for Cross-Department Claim → Settlement
;; -----------------------------------------------------------------------------

(set 'state-spec-wf2
  (sorted-map
    "CLAIM_STATE_INIT"                  (claim-init-state-handler)
    "CLAIM_STATE_GUIDEWIRE_SNAPSHOTTED" (claim-guidewire-snapshotted-state-handler)
    "CLAIM_STATE_MYSQL_VALIDATED"       (claim-mysql-validated-state-handler)
    "CLAIM_STATE_SP_DOCS_COLLECTED"     (claim-sp-docs-collected-state-handler)
    "CLAIM_STATE_GUIDEWIRE_APPROVED"    (claim-guidewire-approved-state-handler)
    "CLAIM_STATE_DONE"                   (claim-done-state-handler)
  ))

;; -----------------------------------------------------------------------------
;; Build the claims connector from the generic factory
;; -----------------------------------------------------------------------------

; register the clam manager for workflow 3 againt the name claim_wf2
(set 'claim-manager-wf2
     (singleton (mk-entity-manager
                  "claim_wf2"            ;; entity kind
                  "claim_id"         ;; primary key field
                  "CLAIM_STATE_INIT" ;; initial state
                  state-spec-wf2)))

(register-connector-factory claim-manager-wf2)

;; Helper to create a new claim connector object via factory
(defun create-claim-wf2 ()
  (new-connector-object claim-manager-wf2))

; AS IS: an event is raised for a state transition. The connetorhub routes the
; event to the correct manager based on the event type. When we create the event
; we register a request ID. The connectorhub includes this request ID in its
; response When we receive the response, we look up the request ID. 


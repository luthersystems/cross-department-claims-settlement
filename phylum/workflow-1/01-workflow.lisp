;; =============================
;; 1) INIT -> MYSQL_RETRIEVED
;; Retrieve cross‑dept claim from Oracle
;; =============================

(defun wf1-claim-init-state-handler ()
  (labels
    ([parse (resp entity)
      ; resp is ch resp
      ; entity is the entity object e.g. claim in this case.
      ; we essentially just parse the incoming request here.
      ;; Prioritize resp (explicit request) over entity (accumulated data)
      ;; For unified process, resp is empty so falls back to entity
      (let* ([policy-id (get-from-resp-or-entity "policy_id" resp entity)]
             [gw-claim-id (or (get resp "gw_claim_id")
                              (get resp "guidewire_claim_id")
                              (get entity "gw_claim_id"))]
             [signer-email (get-from-resp-or-entity "signer_email" resp entity)]
             [signer-name  (get-from-resp-or-entity "signer_name" resp entity)]
             [invoice-amount (get-from-resp-or-entity "invoice_amount" resp entity)]
             [originator-name (get-from-resp-or-entity "originator_name" resp entity)]
             [recipient-name  (get-from-resp-or-entity "recipient_name" resp entity)]
             [issue-date      (get-from-resp-or-entity "issue_date" resp entity)])
        (sorted-map
          "policy_id"          policy-id
          "gw_claim_id"        gw-claim-id
          "signer_email"       signer-email
          "signer_name"        signer-name
          "invoice_amount"     invoice-amount
          "originator_name"    originator-name
          "recipient_name"     recipient-name
          "issue_date"         issue-date))]

     [stage-ephemeral (entity parsed accessors)   
     (vector
        (sorted-map :key "policy_id_ephem"
                    :value (get parsed "policy_id")
                    :drop-state "WF1_CLAIM_STATE_EQUIFAX_VERIFIED"))]

     [stage-durable (entity parsed accessors)
      (sorted-map
        "policy_id"        (get parsed "policy_id")
        "gw_claim_id"      (get parsed "gw_claim_id")
        "signer_email"     (get parsed "signer_email")
        "signer_name"      (get parsed "signer_name")
        "invoice_amount"   (get parsed "invoice_amount")
        "originator_name"  (get parsed "originator_name")
        "recipient_name"   (get parsed "recipient_name")
        "issue_date"       (get parsed "issue_date"))]
    
    [create-events (entity parsed accessors)
      (vector
        (mk-oracle-get-claim-event entity (get parsed "policy_id")))])

    (mk-state-handler
      :next            "WF1_CLAIM_STATE_ORACLE_DETAILS_RETRIEVED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

;; =======================================================================
;; 2) CLAIM_STATE_ORACLE_DETAILS_RETRIEVED -> CLAIM_STATE_EQUIFAX_VERIFIED
;; Validate identity of user using Equifax
;; =======================================================================

;; mk-equifax-verify-event
(defun wf1-claim-oracle-details-retrieved-state-handler ()
  (labels
    ;; parse Oracle Response
    ([parse (resp entity) (parse-oracle-get-claim-response resp)]

     ;; nothing to stage here
     [stage-ephemeral (entity parsed accessors) (vector)]

     ;; store reference to oracle claim
     [stage-durable (entity parsed accessors)
      (sorted-map
        "oracle_claim_id"  (format-string "claim:{}" (get parsed "claim_id"))
        "amount"           (get parsed "amount")
        "status"           (get parsed "status"))]


     ;; no further events
     [create-events (entity parsed accessors)
      (let* ([claimant (get parsed "claimant")])
        (vector
          (mk-equifax-verify-event
            entity claimant)))])

  (mk-state-handler
    :next            "WF1_CLAIM_STATE_EQUIFAX_VERIFIED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))

;; ====================================================
;; 2)  CLAIM_STATE_EQUIFAX_VERIFIED -> CLAIM_STATE_TEAMS_THREAD_CREATED
;; Validate identity of user using Equifax
;; ====================================================

(defun wf1-claim-equifax-verified-state-handler ()
  (labels
    ([parse (resp entity)
  (let* ([parsed (parse-equifax-verify-response resp)]
         [validation (validate-equifax-response parsed)])
    (sorted-map
      "entity_id" (get parsed "entity_id")
      "status"    (get parsed "status")
      "comment"   (get parsed "comment")
      "hit_value_emb" (get parsed "hit_value_emb")
      "hit_value_pep" (get parsed "hit_value_pep")
      "pstatus_det"   (get parsed "pstatus_det")
      "list_matches"  (get parsed "list_matches")
      "validation"    validation))]


     [stage-ephemeral (entity parsed accessors) (vector)]

     [stage-durable (entity parsed accessors)
      (sorted-map
        "equifax_status"      (get parsed "status")
        "equifax_comment"     (get parsed "comment")
        "equifax_hit_value_pep" (get parsed "hit_value_pep")
        "equifax_hit_value_emb" (get parsed "hit_value_emb")
        "equifax_pstatus_det" (get parsed "pstatus_det")

        ; "equifax_validation"    (and validation (get validation "reason"))
        )]

     [create-events (entity parsed accessors)
      (let* ([validation (get parsed "validation")]
             [is-valid (get validation "valid")])
        (if is-valid
          ;; proceed to done state (optionally notify Teams)
          (vector
            (mk-teams-start-thread-event
              entity
              "Equifax Screening Passed"
              (format-string "Claim {} successfully verified with Equifax." (get entity "claim_id"))))
          ;; send alert to compliance team
          (vector
            (mk-teams-start-thread-event
              entity
              "Equifax Screening Alert"
              (format-string
                "Claim {} flagged for review: {}"
                (get entity "claim_id")
                (get validation "reason"))))))])

    (mk-state-handler
      :next            "WF1_CLAIM_TEAMS_THREAD_CREATED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

;; ===================
;; 3) CLAIM_STATE_TEAMS_THREAD_CREATED
;; Create Teams thread and complete workflow
;; ===================

(defun wf1-teams-thread-created-state-handler (&optional next-state after-storage-hook)
  (labels
    ;; parse generic response (also checks for errors)
    ([parse (resp entity)
      (let* ([parsed (parse-generic-resp resp)]
             [thread-id (and parsed (get parsed "thread_id"))]
             [message-id (and parsed (get parsed "message_id"))])
        (when (nil? parsed)
          (set-exception-unexpected "Failed to parse Teams response"))
        (when (nil? thread-id)
          (set-exception-unexpected "Teams response missing thread_id"))
        (sorted-map "thread_id" thread-id "message_id" message-id))]

     ;; nothing to stage here
     [stage-ephemeral (entity parsed accessors) (vector)]

     ;; store thread_id and message_id for later use
     [stage-durable (entity parsed accessors)
      (let* ([thread-id (get parsed "thread_id")]
             [message-id (get parsed "message_id")]
             [result (sorted-map "teams_thread_id" thread-id
                                "teams_message_id" message-id)])
        result)]


     ;; no further events
     [create-events (entity parsed accessors) ()])

  (mk-state-handler
    :next            (or next-state "WF1_CLAIM_TEAMS_THREAD_CREATED")
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events
    :after-storage-hook after-storage-hook)))

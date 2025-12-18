(in-package 'cdcs)

;; =============================
;; 1) INIT -> ORACLE_DETAILS_RETRIEVED
;; Retrieve cross‑dept claim from Oracle
;; =============================

(defun wf1-claim-init-state-handler ()
  (labels
    ([receive (resp entity accessors)
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

     [validate (received entity accessors)
       (when (nil? (get received "policy_id")) (set-exception-business "missing policy_id"))
       received]

     [decide-next-state (validated entity accessors)
       "WF1_CLAIM_STATE_ORACLE_DETAILS_RETRIEVED"]

     [store-ephemeral (entity validated accessors)
       (vector
         (sorted-map :key "policy_id_ephem"
                     :value (get validated "policy_id")
                     :drop-state "WF1_CLAIM_STATE_EQUIFAX_VERIFIED"))]

     [store-durable (entity validated accessors)
       (sorted-map
         "policy_id"        (get validated "policy_id")
         "gw_claim_id"      (get validated "gw_claim_id")
         "signer_email"     (get validated "signer_email")
         "signer_name"      (get validated "signer_name")
         "invoice_amount"   (get validated "invoice_amount")
         "originator_name"  (get validated "originator_name")
         "recipient_name"   (get validated "recipient_name")
         "issue_date"       (get validated "issue_date"))]
    
     [send (entity validated accessors)
       (vector
         (mk-oracle-get-claim-event entity (get validated "policy_id") accessors))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

;; =======================================================================
;; 2) ORACLE_DETAILS_RETRIEVED -> EQUIFAX_VERIFIED
;; Validate identity of user using Equifax
;; =======================================================================

(defun wf1-claim-oracle-details-retrieved-state-handler ()
  (labels
    ([receive (resp entity accessors)
       (parse-oracle-get-claim-response resp)]

     [validate (received entity accessors)
       (when (nil? (get received "claim_id")) (set-exception-business "missing claim_id in oracle response"))
       received]

     [decide-next-state (validated entity accessors)
       "WF1_CLAIM_STATE_EQUIFAX_VERIFIED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
       (sorted-map
         "oracle_claim_id"  (format-string "claim:{}" (get validated "claim_id"))
         "amount"           (get validated "amount")
         "status"           (get validated "status"))]

     [send (entity validated accessors)
       (let* ([claimant (get validated "claimant")])
         (vector
           (mk-equifax-verify-event
             entity claimant accessors)))])

  (mk-state-handler
    :receive           receive
    :validate          validate
    :decide-next-state decide-next-state
    :store-ephemeral   store-ephemeral
    :store-durable     store-durable
    :send              send)))

;; ====================================================
;; 3) EQUIFAX_VERIFIED -> TEAMS_THREAD_CREATED
;; Notify Teams based on Equifax validation result
;; =============================

(defun wf1-claim-equifax-verified-state-handler ()
  (labels
    ([receive (resp entity accessors)
       (let* ([received (parse-equifax-verify-response resp)])
         (sorted-map
           "entity_id"     (get received "entity_id")
           "status"        (get received "status")
           "comment"       (get received "comment")
           "hit_value_emb" (get received "hit_value_emb")
           "hit_value_pep" (get received "hit_value_pep")
           "pstatus_det"   (get received "pstatus_det")
           "list_matches"  (get received "list_matches")))]

     [validate (received entity accessors)
       (let* ([entity-id (get received "entity_id")]
              [status (get received "status")]
              [comment (get received "comment")]
              [hit-value-emb (or (get received "hit_value_emb") 0)]
              [hit-value-pep (or (get received "hit_value_pep") 0)]
              [pstatus-det (or (get received "pstatus_det") "Clear")]
              [list-matches (or (get received "list_matches") (vector))]
              [validation (validate-equifax-response (sorted-map
                                                       "entity_id" entity-id
                                                       "status" status
                                                       "comment" comment
                                                       "hit_value_emb" hit-value-emb
                                                       "hit_value_pep" hit-value-pep
                                                       "pstatus_det" pstatus-det
                                                       "list_matches" list-matches))])
         (when (nil? entity-id)
           (cc:warnf (sorted-map "received" received) "validate: entity_id is missing from received")
           (set-exception-business "missing entity_id"))
         (when (nil? status)    (set-exception-business "missing status"))
         (when (nil? comment)   (set-exception-business "missing comment"))
         (when (nil? validation)    (set-exception-business "missing validation"))
         (assoc received "validation" validation))]

     [decide-next-state (validated entity accessors)
       "WF1_CLAIM_TEAMS_THREAD_CREATED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
       (sorted-map
         "equifax_status"      (get validated "status")
         "equifax_comment"     (get validated "comment")
         "equifax_hit_value_pep" (get validated "hit_value_pep")
         "equifax_hit_value_emb" (get validated "hit_value_emb")
         "equifax_pstatus_det" (get validated "pstatus_det"))]

     [send (entity validated accessors)
       (let* ([validation (get validated "validation")]
              [is-valid (get validation "valid")])
         (if is-valid
           (vector
             (mk-teams-start-thread-event
               entity
               "Equifax Screening Passed"
               (format-string "Claim {} successfully verified with Equifax." (get entity "claim_id"))
               accessors))
           (vector
             (mk-teams-start-thread-event
               entity
               "Equifax Screening Alert"
               (format-string
                 "Claim {} flagged for review: {}"
                 (get entity "claim_id")
                 (get validation "reason"))
               accessors))))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

;; ===================
;; 4) TEAMS_THREAD_CREATED
;; Create Teams thread and complete workflow
;; ===================

(defun wf1-teams-thread-created-state-handler (&optional next-state after-storage-hook)
  (labels
    ([receive (resp entity accessors)
       (let* ([parsed (parse-generic-resp resp)]
              [thread-id (and parsed (get parsed "thread_id"))]
              [message-id (and parsed (get parsed "message_id"))])
         (sorted-map "thread_id" thread-id "message_id" message-id))]

     [validate (received entity accessors)
       (when (nil? (get received "thread_id")) (set-exception-unexpected "Teams response missing thread_id"))
       received]

     [decide-next-state (validated entity accessors)
       (or next-state "WF1_CLAIM_TEAMS_THREAD_CREATED")]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
       (sorted-map "teams_thread_id" (get validated "thread_id")
                    "teams_message_id" (get validated "message_id"))]

     [send (entity validated accessors) (vector)])

  (mk-state-handler
    :receive           receive
    :validate          validate
    :decide-next-state decide-next-state
    :store-ephemeral   store-ephemeral
    :store-durable     store-durable
    :send              send
    :after-storage-hook after-storage-hook)))

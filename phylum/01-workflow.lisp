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
      (let* ([policy-id (or (get entity "policy_id") (get resp "policy_id"))]
             [gw-claim-id (or (get entity "gw_claim_id")
                              (get resp "gw_claim_id")
                              (get resp "guidewire_claim_id"))]
             [signer-email (or (get entity "signer_email") (get resp "signer_email"))]
             [signer-name  (or (get entity "signer_name")  (get resp "signer_name"))]
             [invoice-amount (or (get entity "invoice_amount") (get resp "invoice_amount"))]
             [originator-name (or (get entity "originator_name") (get resp "originator_name"))]
             [recipient-name  (or (get entity "recipient_name")  (get resp "recipient_name"))]
             [issue-date      (or (get entity "issue_date")      (get resp "issue_date"))]
             [chain-to-wf2 (normalize-bool (or (get resp "chain_to_wf2")
                                               (get entity "chain_to_wf2"))
                                           *wf1-chain-enabled*)]
             [chain-to-wf3 (normalize-bool (or (get resp "chain_to_wf3")
                                               (get entity "chain_to_wf3"))
                                           *wf2-chain-enabled*)])
        (sorted-map
          "policy_id"          policy-id
          "gw_claim_id"        gw-claim-id
          "signer_email"       signer-email
          "signer_name"        signer-name
          "invoice_amount"     invoice-amount
          "originator_name"    originator-name
          "recipient_name"     recipient-name
          "issue_date"         issue-date
          "chain_to_wf2"       chain-to-wf2
          "chain_to_wf3"       chain-to-wf3))]

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
        "issue_date"       (get parsed "issue_date")
        "chain_to_wf2"     (get parsed "chain_to_wf2")
        "chain_to_wf3"     (get parsed "chain_to_wf3"))]
    
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
;; 2)  CLAIM_STATE_EQUIFAX_VERIFIED -> CLAIM_STATE_DONE
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
      :next            "WF1_CLAIM_STATE_DONE"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

;; ===================
;; 2) CLAIM_STATE_DONE
;; Validate identity 
;; ===================

(defun wf1-claim-done-state-handler ()
  (labels
    ;; parse generic response (also checks for errors)
    ([parse (resp entity) (parse-generic-resp resp)]

     ;; nothing to stage here
     [stage-ephemeral (entity parsed accessors) (vector)]

     ;; store reference to oracle claim
     [stage-durable (entity parsed accessors) ()]


     ;; no further events
     [create-events (entity parsed accessors) ()])

  (mk-state-handler
    :next            "WF1_CLAIM_STATE_DONE"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))

(defun build-event (entity req action sys-name)
  (sorted-map
    "oid" (get entity "claim_id")
    "key" (mk-uuid)
    "pdc" "private"
    "msp" "Org1MSP"
    "sys" sys-name
    "eng" action
    "req" req))

(defun mk-oracle-get-claim-event (entity policy-id) 
  (let* ([sql (format-string 
                "SELECT CLAIM_ID, POLICY_ID, AMOUNT, STATUS, CLAIMANT_FIRST_NAME, CLAIMANT_LAST_NAME, CLAIMANT_DOB, CLAIMANT_ADDRESS, CLAIMANT_NATIONAL_ID FROM CLAIMS WHERE POLICY_ID = '{}'" 
                policy-id)] 
         [req (mk-connector-req 
          (sorted-map "kind" "KIND_ORACLE_READONLY" "operation" "execute_query" "args" (sorted-map "query" sql)))]) 
        (build-event entity req "get claim" "ORACLE")))

(defun parse-oracle-get-claim-response (resp)
  (let* ([j-map (parse-generic-resp resp)]
         [rows  (get j-map "rows")]
         [row   (first rows)])
    (sorted-map
      "claim_id"  (get row "CLAIM_ID")
      "policy_id" (get row "POLICY_ID")
      "amount"    (get row "AMOUNT")
      "status"    (get row "STATUS")
      "claimant"  (sorted-map
                    "first_name"  (get row "CLAIMANT_FIRST_NAME")
                    "last_name"   (get row "CLAIMANT_LAST_NAME")
                    "dob"         (get row "CLAIMANT_DOB")
                    "address"     (get row "CLAIMANT_ADDRESS")
                    "national_id" (get row "CLAIMANT_NATIONAL_ID"))))
)

(defun mk-equifax-verify-event (entity claimant)
  (let* ([req (sorted-map
                "equifax"
                (sorted-map
                  "entity_screening_request"
                  (sorted-map
                    "entity_id" (get entity "claim_id")
                    "first_name" (get claimant "first_name")
                    "last_name" (get claimant "last_name")
                    "birth_date" (get claimant "dob")
                    "address" (get claimant "address")
                    "postal_code" "SW1A"
                    "address_country_code" "GB"
                    "federal_id" (get claimant "national_id"))))])
    (build-event entity req "verify claimant" "EQUIFAX")))

(defun parse-equifax-verify-event (entity claimant)
  (let* ([req (sorted-map
                "equifax"
                (sorted-map
                  "entity_screening_request"
                  (sorted-map
                    "entity_id" (get entity "claim_id")
                    "first_name" (get claimant "first_name")
                    "last_name" (get claimant "last_name")
                    "birth_date" (get claimant "dob")
                    "address" (get claimant "address")
                    "postal_code" "SW1A"
                    "address_country_code" "GB"
                    "federal_id" (get claimant "national_id"))))])
    (build-event entity req "verify claimant" "EQUIFAX")))


(defun mk-teams-start-thread-event (entity title content)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind"      "KIND_MICROSOFT_TEAMS"
                  "operation" "start_thread"
                  "args"      (sorted-map
                                 "title"   title
                                 "content" content)))]
         [action "start thread"]
         [sys-name "TEAMS"])
    (build-event entity req action sys-name)))

(defun parse-equifax-verify-response (resp)
  (let* ([j-map (parse-generic-resp resp)]
         [eqfx   (get j-map "equifax")] 
         [response (get eqfx "entity_screening_response")]
         [matches  (and response (get response "list_matches"))])
      (sorted-map
        "entity_id"       (and response (get response "entity_id"))
        "status"          (and response (get response "status"))
        "comment"         (and response (get response "comment"))
        "hit_value_emb"   (and response (get response "hit_value_emb"))
        "hit_value_pep"   (and response (get response "hit_value_pep"))
        "pstatus_det"     (and response (get response "pstatus_det"))
        "list_matches"    matches)))

(defun validate-equifax-response (parsed)
  (let* ([status (get parsed "status")]
         [pep    (get parsed "hit_value_pep")]
         [emb    (get parsed "hit_value_emb")]
         [status-str (if (list? status) (first status) status)])
         (sorted-map "valid" true "reason" "Non-critical match or manual review passed")))
;TODO add this validation in
      ;   (cond
      ; ((and (string= status-str "Check")
      ;       (or (> pep 90) (> emb 90)))
      ;   (sorted-map "valid" false "reason" "High-risk claimant match found"))
      ; ((string= status-str "Clear")
      ;   (sorted-map "valid" true "reason" "No match found"))
      ; (t
      ;   (sorted-map "valid" true "reason" "Non-critical match or manual review passed")))))

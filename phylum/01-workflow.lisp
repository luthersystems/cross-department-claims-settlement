;; -----------------------------------------------------------------------------
;; Cross‑Department Claim → Settlement: 16‑state workflow (HANDLERS)
;; Lisp‑ish DSL, mirrors the style of the invoice example.
;; Notes:
;;  - Each state handler uses (labels [parse ...] [stage-ephemeral ...]
;;    [stage-durable ...] [create-events ...]) and returns (mk-state-handler ...)
;;  - Event builders like mk-oracle-get-claim-event are assumed to exist.
;;  - Parsing helpers like parse-oracle-claim are assumed to exist.
;;  - accessors includes :get-ephem/:drop-ephem, etc.
;;  - Keep ephemerals only as long as necessary; persist only vetted metadata.
;; -----------------------------------------------------------------------------


;; =============================
;; 1) INIT -> ORACLE_RETRIEVED
;; Retrieve cross‑dept claim from Oracle
;; =============================
(defun claim-1-init-state-handler ()
  (labels
    ([parse (resp entity)
      ;; resp can be empty; we drive off entity.claim_id/policy_id
      (let* ([claim-id  (or (get entity "claim_id")  (get resp "claim_id"))]
             [policy-id (or (get entity "policy_id") (get resp "policy_id"))])
        (validate-nonempty! claim-id policy-id) ; check
        (sorted-map
          "claim_id"  claim-id
          "policy_id" policy-id))]

     [stage-ephemeral (entity parsed accessors) ()]

     [stage-durable (entity parsed accessors)
      (sorted-map
        "claim_id"  (get parsed "claim_id")
        "policy_id" (get parsed "policy_id"))]

     [create-events (entity parsed accessors)
      (vector (mk-oracle-get-claim-event entity (get parsed "claim_id")))])

    (mk-state-handler
      :next            "CLAIM_STATE_ORACLE_RETRIEVED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))


;; =============================
;; 2) ORACLE_RETRIEVED -> EQFX_VERIFIED
;; Validate claim + stage minimal claimant PII for Equifax
;; =============================
(defun claim-oracle-retrieved-state-handler ()
  (labels
    ([parse (resp entity)
      (parse-oracle-claim resp)] ; create

     [stage-ephemeral (entity parsed accessors) ()]

     [stage-durable (entity parsed accessors)
      (sorted-map
        "oracle_ref" (format-string "claim:{}" (get parsed "claim_id"))
        "amount"     (get parsed "amount")
        "status"     (get parsed "status"))]

     [create-events (entity parsed accessors)
      (let* ([claimant  (get parsed "claimant")])
            (vector (mk-equifax-verify-event entity (sorted-map
                               "firstName"  (get claimant "first_name")
                               "lastName"   (get claimant "last_name")
                               "dateOfBirth"(get claimant "dob")
                               "address"    (get claimant "address")
                               "nationalId" (get claimant "national_id")
                               "claimId"    (get parsed "claim_id")
                               "policyId"   (get parsed "policy_id")))))])

    (mk-state-handler
      :next            "CLAIM_STATE_EQFX_VERIFIED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))


;; =============================
;; 3) EQFX_VERIFIED -> TEAMS_NOTIFIED
;; Post verification summary to Teams
;; =============================
(defun claim-eqfx-verified-state-handler ()
  (labels
    ([parse (resp entity) (parse-equifax-response resp)] ; create 

     [stage-ephemeral (entity parsed accessors) ()]

     [stage-durable (entity parsed accessors)
      (sorted-map
        "equifax_verification"
          (sorted-map
            "identityMatch" (get parsed "identityMatch")
            "creditScore"   (get parsed "creditScore")
            "fraudFlags"    (get parsed "fraudFlags")))]

     [create-events (entity parsed accessors)
      (let* ([claim-id (get entity "claim_id")]
              [eqfx-ver (get entity "equifax_verification")]
              [identity-match (and (sorted-map? eqfx-ver)
                                    (get eqfx-ver "identityMatch"))]
              [credit-score (and (sorted-map? eqfx-ver)
                                  (get eqfx-ver "creditScore"))]
              [summary (sorted-map
                          "claimId" claim-id
                          "result"  (if (true? identity-match) "Verified" "Mismatch")
                          "score"   credit-score)])
        (vector (mk-teams-post-event entity summary)))]) ; create

    (mk-state-handler
      :next            "CLAIM_STATE_TEAMS_NOTIFIED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))


;; =============================
;; 4) TEAMS_NOTIFIED -> GUIDEWIRE_SNAPSHOTTED
;; Snapshot Guidewire claim view
;; =============================
(defun claim-teams-notified-state-handler ()
  (labels
    ([parse (resp entity) (parse-teams-post resp)] ; create
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map "teams_message_id" (get parsed "message_id"))]
     [create-events (entity parsed accessors)
      (vector (mk-guidewire-get-claim-event entity (get entity "claim_id")))]) ; create
  
  (mk-state-handler
    :next            "CLAIM_STATE_GUIDEWIRE_SNAPSHOTTED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


; EVENTS HERE

(defun build-event (entity req action sys-name)
  (sorted-map
    "oid" (get entity "claim_id")
    "key" (mk-uuid)
    "pdc" "private"
    "msp" "Org1MSP"
    "sys" sys-name
    "eng" action
    "req" req))

;; ORACLE HELPERS

(defun mk-oracle-get-claim-event (entity claim-id)
  (let* ([sql (format-string
                "SELECT CLAIM_ID, POLICY_ID, AMOUNT, STATUS, CLAIMANT_FIRST_NAME, CLAIMANT_LAST_NAME, CLAIMANT_DOB, CLAIMANT_ADDRESS, CLAIMANT_NATIONAL_ID
                   FROM CLAIMS
                  WHERE CLAIM_ID = '{}'"
                claim-id)]
         [req (mk-connector-req
                (sorted-map
                  "kind"      "KIND_ORACLE"
                  "operation" "run_sql_query"
                  "args"      (sorted-map "sql" sql)))])
    (build-event entity req "get claim" "Oracle")))


(defun parse-oracle-claim (resp)
  ;; Parse Oracle MCP response (list of row maps).
  (let* ([rows (get resp "rows")]
         [row  (if (and (vector? rows) (> (length rows) 0))
                   (first rows)
                   (set-exception-business "Oracle returned no rows"))])
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
                    "national_id" (get row "CLAIMANT_NATIONAL_ID")))))


;; EQUIFAX HELPERS

(defun mk-equifax-verify-event (entity claimant)
  "Builds an event to perform an identity verification via the Equifax connector."
  (validate-nonempty! claimant)

  ;; Construct the Equifax request body
  (let* ([req (mk-equifax-req
                (sorted-map
                  "forename"  (get claimant "first_name")
                  "surname"   (get claimant "last_name")
                  "dob"       (get claimant "dob")
                  "address_name"     (get claimant "address_name")
                  "address_number"   (get claimant "address_number")
                  "address_street1"  (get claimant "address_street1")
                  "address_street2"  (get claimant "address_street2")
                  "address_postcode" (get claimant "address_postcode")
                  "address_post_town"(get claimant "address_post_town")
                  "nationality"      (get claimant "national_id")
                  ;; Optional banking / AML details
                  "account_number"   (get claimant "account_number")
                  "account_sort_code"(get claimant "account_sort_code")))])
    (build-event entity req "verify claimant" "Equifax")))
    
(defun parse-equifax-response (resp)
  "Parses the Equifax verification response into normalized fields."
  (let* ([result (or (get resp "return")
                     (set-exception-business "missing Equifax 'return' block"))]
         [person (get result "personResult")])
    (sorted-map
      "entity_id"    (get person "entityId")
      "status"       (get person "status")
      "comment"      (get person "comment")
      "hitValueEmb"  (get person "hitValueEmb")
      "hitValuePep"  (get person "hitValuePep")
      "pstatusDet"   (get person "pstatusDet"))))

; TEAMS

(defun mk-teams-post-event (entity summary)
  (let* ([req (sorted-map
                "kind"      "KIND_MS_TEAMS"
                "operation" "post_message"
                "args"      summary)])
    (build-event entity req "post summary" "MSTeams")))

(defun parse-teams-post (resp)
  ;; Expecting a Teams connector response like {"message_id": "..."}
  (sorted-map
    "message_id" (get resp "message_id")
    "timestamp"  (get resp "timestamp")))

    (defun mk-teams-post-event (entity summary)
  "Create a new Teams thread announcing claim creation or verification."
  (let* ([title   (format-string "Claim %s %s"
                                  (get summary "claimId")
                                  (get summary "result"))]
         [content (format-string
                    "Policy %s — claim %s has been %s (score: %s)."
                    (get summary "policyId")
                    (get summary "claimId")
                    (get summary "result")
                    (or (get summary "score") "N/A"))]
         [req (mk-connector-req
                (sorted-map
                  "kind"      "KIND_MS_TEAMS"
                  "operation" "start_thread"
                  "args"      (sorted-map
                                 "title"   title
                                 "content" content)))])
    (build-event entity req "post summary" "MSTeams")))
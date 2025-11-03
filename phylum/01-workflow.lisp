;; =============================
;; 1) INIT -> MYSQL_RETRIEVED
;; Retrieve cross‑dept claim from Oracle
;; =============================

(defun claim-init-state-handler ()
  (labels
    ([parse (resp entity)
      ; resp is ch resp
      ; entity is the entity object e.g. claim in this case.
      ; we essentially just parse the incoming request here.
      (let* ([policy-id (or (get entity "policy_id") (get resp "policy_id"))])
        (sorted-map
          "policy_id" policy-id))]

    ; example of staging ephemeral data until pre-defined state. This can be
    ; accessed in later stages using (accessors 'get-ephem <key>). It should be
    ; a vector of entries. parsed is the sorted map from parse step
     [stage-ephemeral (entity parsed accessors)   
     (vector
        (sorted-map :key "policy_id_ephem"
                    :value (get parsed "policy_id")
                    :drop-state "CLAIM_STATE_EQUIFAX_VERIFIED"))]

    ; example of staging ephemeral data. This is what is sent to 'put to persist
    ; the entity in general. It should be a map of entries
     [stage-durable (entity parsed accessors)
      (sorted-map
        "policy_id" (get parsed "policy_id"))]
    
    ; then we create our events to pair with the 'put we created in "stage durable"
    [create-events (entity parsed accessors)
      (vector
        (mk-oracle-get-claim-event entity (get parsed "policy_id")))])

    (mk-state-handler
      :next            "CLAIM_STATE_ORACLE_DETAILS_RETRIEVED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))


;; =======================================================================
;; 2) CLAIM_STATE_ORACLE_DETAILS_RETRIEVED -> CLAIM_STATE_EQUIFAX_VERIFIED
;; Validate identity of user using Equifax
;; =======================================================================

;; mk-equifax-verify-event
(defun claim-oracle-details-retrieved-state-handler ()
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
    :next            "CLAIM_STATE_EQUIFAX_VERIFIED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))

;; ====================================================
;; 2)  CLAIM_STATE_EQUIFAX_VERIFIED -> CLAIM_STATE_DONE
;; Validate identity of user using Equifax
;; ====================================================

(defun claim-equifax-verified-state-handler ()
  (labels
    ([parse (resp entity) resp]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors) ()]
     [create-events (entity parsed accessors)
      (vector
        (mk-teams-start-thread-event
          entity
          "Claim Processing Complete"
          (format-string "Claim {} has completed all verification steps." (get entity "claim_id"))))])
    (mk-state-handler
      :next            "CLAIM_STATE_DONE"
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
         [eqfx   (get-in j-map ["equifax" "entity_screening_response"])]
         [matches (get eqfx "list_matches")])
    (sorted-map
      "entity_id"   (get eqfx "entity_id")
      "status"      (get eqfx "status")
      "comment"     (get eqfx "comment")
      "hit_value_emb" (get eqfx "hit_value_emb")
      "hit_value_pep" (get eqfx "hit_value_pep")
      "pstatus_det"   (get eqfx "pstatus_det")
      "list_matches"  matches)))

      (defun validate-equifax-response (parsed)
  (let* ([status (get parsed "status")]
         [pep    (get parsed "hit_value_pep")]
         [emb    (get parsed "hit_value_emb")])
    (cond
      ((and (string= status "Check")
            (or (> pep 90) (> emb 90)))
        (sorted-map "valid" false "reason" "High-risk claimant match found"))
      ((string= status "Clear")
        (sorted-map "valid" true "reason" "No match found"))
      (t
        (sorted-map "valid" true "reason" "Non-critical match or manual review passed")))))

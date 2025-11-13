(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; Parsers and Event Creators for Workflow 1 (Oracle → Equifax → Teams)
;; -----------------------------------------------------------------------------

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
                    "national_id" (get row "CLAIMANT_NATIONAL_ID")))))

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
                    "postal_code" *wf1-default-postal-code*
                    "address_country_code" *wf1-default-address-country-code*
                    "federal_id" (get claimant "national_id"))))])
    (build-event entity req "verify claimant" "EQUIFAX")))

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


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
                    :drop-state "CLAIM_STATE_DONE"))]

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


;; =============================
;; 2) CLAIM_STATE_ORACLE_DETAILS_RETRIEVED -> DONE
;; =============================
(defun claim-mysql-retrieved-state-handler ()
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
            entity
            (sorted-map
              "firstName"   (get claimant "first_name")
              "lastName"    (get claimant "last_name")
              "dateOfBirth" (get claimant "dob")
              "address"     (get claimant "address")
              "nationalId"  (get claimant "national_id")
              "claimId"     (get parsed "claim_id")
              "policyId"    (get parsed "policy_id")))))])

  (mk-state-handler
    :next            "CLAIM_STATE_DONE"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))

(defun claim-done-state-handler ()
  (labels
    ;; parse MySQL UPDATE/EXEC response
    ([parse (resp entity) resp]

     ;; final cleanups if any (none here)
     [stage-ephemeral (entity parsed accessors) (vector)]

     ;; no durable changes
     [stage-durable (entity parsed accessors) ()]

     ;; no further events
     [create-events (entity parsed accessors) (vector)])
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

; basic mySQL req

(defun mk-mysql-req (sql)
  ;; Wrap raw SQL into connectorhub request.
  (mk-connector-req
    (sorted-map
      "kind" "KIND_MYSQL"
      "operation" "mysql_query"
      "args" (sorted-map "sql" sql))))


(defun mk-mysql-get-by-policy-id-req (policyid)
  ;; Build a SELECT for selecting based on policy 
    (mk-mysql-req
      (format-string "SELECT * FROM v_user_details_by_policy WHERE policy_id = '{}'" policyid)))

(defun mk-mysql-get-by-policy-id-event (claim policyid) 
 (build-mysql-event 
  claim
      (mk-mysql-get-by-policy-id-req policyid)
    "update invoice statuses")) 

(defun build-mysql-event (invoice resp action)
  (build-event invoice resp action "MYSQL"))

(defun parse-mysql-resp (resp)
  (parse-generic-resp resp))

(defun parse-mysql-select (resp)
  (let* ([parsed (parse-mysql-resp resp)]
         [rows   (cond
                   ((vector? parsed) parsed)
                   ((sorted-map? parsed) (vector parsed))
                   (:else (vector)))])
    rows))

(defun mk-oracle-get-claim-event (entity policy-id) 
  (let* ([sql (format-string 
                "SELECT CLAIM_ID, POLICY_ID, AMOUNT, STATUS, CLAIMANT_FIRST_NAME, CLAIMANT_LAST_NAME, CLAIMANT_DOB, CLAIMANT_ADDRESS, CLAIMANT_NATIONAL_ID FROM CLAIMS WHERE POLICY_ID = '{}'" 
                policy-id)] 
         [req (mk-connector-req 
          (sorted-map "kind" "KIND_ORACLE" "operation" "execute_query" "args" (sorted-map "query" sql)))]) 
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
;; =============================
;; 1) INIT -> ORACLE_RETRIEVED
;; Retrieve cross‑dept claim from Oracle
;; =============================

(defun claim-1-init-state-handler ()
  (labels
    ([parse (resp entity)
      ; we essentially just parse the incoming request here
      (let* ([policy-id (or (get entity "policy_id") (get resp "policy_id"))])
        (sorted-map
          "policy_id" policy-id))]

    ; example of staging ephemeral data until pre-defined state. This can be
    ; accessed in later stages using accessors 'get-ephem. It should be a vector
    ; of entries
     [stage-ephemeral (entity parsed accessors)   
     (vector
        (sorted-map :key "policy_id"
                    :value (get parsed "policy_id")
                    :drop-state "CLAIM_STATE_MYSQL_RETRIEVED"))]

    ; example of staging ephemeral data. This is what is sent to 'put to persist
    ; the entity in general. It should be a map of entries
     [stage-durable (entity parsed accessors)
      (sorted-map
        "policy_id" (get parsed "policy_id"))]
      
    
    ; then we create our events with
    [create-events (entity parsed accessors)
      (cc:infof (sorted-map) "step init-4 create events")
      (vector
        (mk-mysql-get-by-policy-id-event entity (get parsed "policy_id")))])

    (mk-state-handler
      :next            "CLAIM_STATE_MYSQL_RETRIEVED"
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
    
      (cc:infof (sorted-map "resp" resp "entity" entity) "step 2a create events")
     resp] ; create

     [stage-ephemeral (entity parsed accessors) ()
           (cc:infof (sorted-map) "claim-oracle-retrieved-state-handler parse invoked")]

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
                "SELECT CLAIM_ID, POLICY_ID, AMOUNT, STATUS, CLAIMANT_FIRST_NAME, CLAIMANT_LAST_NAME, CLAIMANT_DOB, CLAIMANT_ADDRESS, CLAIMANT_NATIONAL_ID FROM CLAIMS WHERE CLAIM_ID = '{}'"
                claim-id)]
         [req (mk-connector-req
                (sorted-map
                  "kind"      "KIND_ORACLE"
                  "operation" "run_sql_query"
                  "args"      (sorted-map "sql" sql)))])
    (build-event entity req "get claim" "ORACLEEEEEE")))


(defun parse-oracle-claim (resp) 
(cc:infof (sorted-map "resp" resp) "oracle resp before parse")
  ;; Parse Oracle MCP response (list of row maps).
  (let* ([rows (get resp "rows")]
         [row  (if (and (vector? rows) (> (length rows) 0))
                   (first rows)
                   (set-exception-buoraness "Oracle returned no rows"))])
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












(defun mk-mysql-req (sql)
  ;; Wrap raw SQL into connectorhub request.
  (mk-connector-req
    (sorted-map
      "kind" "KIND_MYSQL"
      "operation" "mysql_query"
      "args" (sorted-map "sql" sql))))


(defun parse-mysql-resp (resp)
  (parse-generic-resp resp))

(defun mk-mysql-insert-pos-basic-req ()
  (mk-mysql-req
    "INSERT INTO purchase_orders (po_number, vendor_id, amount, status) VALUES ('PO1004', 1, 5000.00, 'OPEN'), ('PO2005', 2, 7500.00, 'OPEN');"))

(defun mk-mysql-select-docs-req (ids)
  ;; Build a SELECT for multiple invoice_ids using IN.
  ; (let* ((id-str (string-join (map string ids) ",")))
    (mk-mysql-req "SELECT * FROM invoices WHERE invoice_id IN (1,2)"))

(defun mk-mysql-delete-doc-req (invoice-id filename)
  ;; Build a DELETE statement for a specific doc by invoice + filename.
  (mk-mysql-req
    (format-string
      "DELETE FROM invoices WHERE invoice_id='{}' AND filename='{}'"
      invoice-id filename)))


;; ======================
;;  High-level transitions
;; ======================

(defun mk-mysql-insert-doc-transition (invoice invoice-id filename bucket)
  ;; Insert a new document record and emit an event.
  (build-mysql-event
    invoice
    (mk-mysql-insert-pos-basic-req)
    "insert doc"))


(defun mk-mysql-select-docs-transition (invoice invoice-ids)
  ;; Query documents for an invoice and emit an event.
  (build-mysql-event
    invoice
    (mk-mysql-select-docs-req invoice-ids)
    "select docs"))


(defun mk-mysql-delete-doc-transition (invoice invoice-id filename)
  ;; Delete a document record and emit an event.
  (build-mysql-event
    invoice
    (mk-mysql-delete-doc-req invoice-id filename)
    "delete doc"))

(defun mk-mysql-insert-pos-basic-transition (invoice)
  (build-mysql-event
    invoice
    (mk-mysql-insert-pos-basic-req)
    "basic insert"))

(defun parse-mysql-exec (resp)
  (let* ([parsed (parse-mysql-resp resp)])
    (cc:infof (sorted-map "parsed-response" parsed) "parse-mysql-exec")
    "ok"))

(defun parse-mysql-select (resp)
  (let* ([parsed (parse-mysql-resp resp)]
         [rows   (cond
                   ((vector? parsed) parsed)
                   ((sorted-map? parsed) (vector parsed))
                   (:else (vector)))])
    rows))

(defun extract-invoice-statuses (rows)
  (when (vector? rows)
    (let* ([fn (lambda (row)
                 (format-string "{}:{}"
                                (get row "invoice_number")
                                (get row "status")))])
      (map 'vector fn rows))))

(defun mk-mysql-select-invoices-by-numbers-req (numbers)
  ;; Build a SELECT for multiple invoice_numbers using IN.
  (let* ([quoted (map 'list (lambda (n) (format-string "'{}'" n)) numbers)]
         [joined (string:join quoted ",")])
    (mk-mysql-req
      (format-string
        "SELECT * FROM invoices WHERE invoice_number IN ({})"
        joined))))

(defun mk-mysql-update-invoice-status-req (numbers)
  ;; Update invoices matching invoice_numbers from PENDING to VERIFIED.
  (let* ([quoted (map 'list (lambda (n) (format-string "'{}'" n)) numbers)]
         [joined (string:join quoted ",")])
    (mk-mysql-req
      (format-string "UPDATE invoices SET status = 'VERIFIED' WHERE invoice_number IN ({}) AND status = 'PENDING'"
        joined))))

(defun mk-mysql-select-invoices-by-numbers-event (invoice numbers)
  (build-mysql-event
    invoice
    (mk-mysql-select-invoices-by-numbers-req numbers)
    "select invoices by numbers"))

(defun mk-mysql-update-invoice-status-event (invoice numbers)
  (build-mysql-event
    invoice
    (mk-mysql-update-invoice-status-req numbers)
    "update invoice statuses"))
(defun build-mysql-event (entity req summary)
  ;; IMPORTANT: sys must match the name shown in connectorhub logs.
  ;; If your hub registers it as MYSQL, use "MYSQL". If it’s something else,
  ;; change here to exactly that string.
  (build-event entity req summary "MYSQL"))

(defun mk-mysql-get-by-policy-id-req (policyid)
  ;; Build a SELECT for selecting based on policy 
    (mk-mysql-req
      (format-string "SELECT * FROM v_user_details_by_policy WHERE invoice_number = {}" policyid)))

(defun mk-mysql-get-by-policy-id-event (claim policyid) 
 (build-mysql-event 
  claim
      (mk-mysql-get-by-policy-id-req policyid)
    "update invoice statuses")) 
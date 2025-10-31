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
    ; accessed in later stages using accessors 'get-ephem. It should be a vector
    ; of entries. parsed is the sorted map from parse step
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
        (mk-mysql-get-by-policy-id-event entity (get parsed "policy_id")))])

    (mk-state-handler
      :next            "CLAIM_STATE_MYSQL_RETRIEVED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))


;; =============================
;; 2) MYSQL_RETRIEVED -> DONE
;; =============================
(defun claim-mysql-retrieved-state-handler ()
  (labels
    ;; parse MySQL UPDATE/EXEC response
    ([parse (resp entity) resp]

     ;; final cleanups if any (none here)
     [stage-ephemeral (entity parsed accessors) 
      (let* ([entity-id    (get entity "claim_id")]
             [get-ephem    (get accessors :get-ephem)]
             [policy-id-ephem (get-ephem "policy_id_ephem")])
             (cc:infof (sorted-map "policy-id-ephem!" policy-id-ephem) "ephemeral data example!"))
     (vector)]

     ;; no durable changes
     [stage-durable (entity parsed accessors) ()]

     ;; no further events
     [create-events (entity parsed accessors)
      (vector)])
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
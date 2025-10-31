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

(defun build-mysql-event (invoice resp action)
  (build-event invoice resp action "MYSQL"))

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

(defun parse-mysql-resp (resp)
  (parse-generic-resp resp))
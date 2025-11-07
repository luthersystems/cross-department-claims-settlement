
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
     [stage-ephemeral (entity parsed accessors) (vector)]

    ; example of staging ephemeral data. This is what is sent to 'put to persist
    ; the entity in general. It should be a map of entries
     [stage-durable (entity parsed accessors)
      (sorted-map
        "policy_id" (get parsed "policy_id"))]
    
    ; then we create our events to pair with the 'put we created in "stage durable"
      [create-events (entity parsed accessors)
      (vector)])


    (mk-state-handler
      :next            "CLAIM_STATE_APPROVED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))



(defun claim-state-approved-handler ()
  (labels
    ([parse (resp entity) (
      (cc:infof (sorted-map "resp" resp) "i have made it") resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map "sn_state" (get parsed "state") "loop" 14)]
     [create-events (entity parsed accessors)
      (vector (mk-sap-execute-payment-event entity
                (sorted-map "invoice_id"    (get entity "invoice_id")
                            "claim_id"      (get entity "claim_id")
                            "amount"        (get entity "amount")
                            "payment_memo"  "Inter-entity settlement")))])
  (mk-state-handler
    :next            "CLAIM_STATE_SAP_PAID"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 15) SAP_PAID -> NETSUITE_RECONCILED
;; NetSuite: reconciliation entry
;; =============================
(defun claim-state-done-handler ()
  (labels
    ([parse (resp entity) (parse-sap-payment resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map "payment_txn_id" (get parsed "transaction_id")
                  "paid_amount"   (get parsed "amount")
                  "gl_post_ref"   (get parsed "posting_ref")
                  "loop"          15)]
     [create-events (entity parsed accessors)
      (vector (mk-netsuite-record-recon-event entity
                (sorted-map "invoice_id" (get entity "invoice_id")
                            "claim_id"  (get entity "claim_id")
                            "amount"    (get entity "paid_amount")
                            "txn_id"    (get entity "payment_txn_id"))))])
  (mk-state-handler
    :next            "CLAIM_STATE_NETSUITE_RECONCILED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 16) NETSUITE_RECONCILED -> DONE
;; Aggregate final status and complete
;; =============================
(defun claim-netsuite-reconciled-state-handler ()
  (labels
    ([parse (resp entity) (parse-netsuite-recon resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "recon_entry_id" (get parsed "entry_id")
        "final_status"   (decide-final-status entity)
        "loop"           16)]
     [create-events (entity parsed accessors)
      (vector)])
  (mk-state-handler
    :next            "CLAIM_STATE_DONE"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))












(defun mk-invoice-oid-index-key (invoice-id)
  ;; Namespaced key. Use sidedb "private" for privacy (preferred), fall back OK.
  (join-index-cols "sandbox" "invoice_oid_idx" invoice-id))

(defun index-get-oid-by-invoice (invoice-id)
  ;; Prefer sidedb; optionally fall back to statedb for older data.
  (let* ([k (mk-invoice-oid-index-key invoice-id)]
         [oid (or (sidedb:get k) (statedb:get k))])
    oid))


(defun index-put-invoice-oid! (invoice-id oid)
  ;; Called when an invoice is created/learned in your object FSM.
  (validate-nonempty-string (sorted-map "invoice_id" invoice-id) "invoice_id")
  (validate-nonempty-string (sorted-map "oid" oid) "oid")
  (sidedb:put (mk-invoice-oid-index-key invoice-id) (to-string oid)))


(defun register-pause-callback (factory entity)
  (let* ([rid rid]  ; the same one your webhook connector listens for
         [oid (get entity "invoice_id")]
         [rid (mk-uuid)] ; e.g. update_payment_status_<invoice_id>
         [key (mk-uuid)]
         [pdc "private"]
         [placeholder (json:dump-bytes (sorted-map "pause" true))]
         [ctx (sorted-map
                 "oid" oid
                 "key" key
                 "pdc" pdc)]
         [handler-name (factory 'name)])
    ;; make cleanup deterministic
    (cc:storage-put-private pdc key placeholder)
    (connector-handlers 'register-request-callback rid handler-name ctx)
    rid))
    
(defun build-event (entity req action sys-name)
  (cc:infof (sorted-map "event" (sorted-map
    "oid" (get entity "claim_id")
    "key" (mk-uuid)
    "pdc" "private"
    "msp" "Org1MSP"
    "sys" sys-name
    "eng" action
    "req" req)) "event for {}" sys-name)
  (sorted-map
    "oid" (get entity "claim_id")
    "key" (mk-uuid)
    "pdc" "private"
    "msp" "Org1MSP"
    "sys" sys-name
    "eng" action
    "req" req))

(in-package 'sandbox)

;; -----------------------------------------------------------------------------
;; Helper constructors and parsers for Workflow 5 (SAP payment acknowledgement)
;; -----------------------------------------------------------------------------

(defun wf5-mk-sap-store-payment-event (entity sap-payload)
  (let* ([payment-id   (or (get sap-payload "payment_id") "PAYM-002")]
         [invoice-id   (or (get sap-payload "invoice_id") "INV-1002")]
         [reference    (or (get sap-payload "reference") "Batch-Nov-01")]
         [vendor-id    (or (get sap-payload "vendor_id") "VEND-001")]
         [amount       (or (get sap-payload "amount") 2500.00)]
         [currency     (or (get sap-payload "currency") "USD")]
         [method       (or (get sap-payload "payment_method") "EFT")]
         [payment-date (or (get sap-payload "payment_date") "2025-11-06")]
         [status       (or (get sap-payload "status") "PENDING")]
         [query (format-string
                  "INSERT INTO PAYMENTS_STAGING (PAYMENT_ID, INVOICE_ID, REFERENCE, VENDOR_ID, AMOUNT, CURRENCY, PAYMENT_METHOD, PAYMENT_DATE, STATUS) VALUES ('{}', '{}', '{}', '{}', {}, '{}', '{}', '{}', '{}');"
                  payment-id invoice-id reference vendor-id amount currency method payment-date status)]
         [req (mk-connector-req
                (sorted-map
                  "kind" "KIND_SAP_HANA"
                  "operation" "hana_execute_query"
                  "args" (sorted-map "query" query)))])
    (build-event entity req "store sap payment" "SAP")))

(defun wf5-parse-sap-payment (resp)
  (let* ([parsed (parse-generic-resp resp)]
         [payment (or (get parsed "payment") parsed)])
    (sorted-map
      "transaction_id" (or (get payment "transaction_id") "SAP-TXN-1001")
      "amount"         (or (get payment "amount") 2500.00)
      "posting_ref"    (or (get payment "posting_ref") "SAP-POST-REF")
      "status"         (or (get payment "status") "posted"))))

;; -----------------------------------------------------------------------------
;; State handlers (WF5 ends after SAP payment acknowledgement)
;; -----------------------------------------------------------------------------

(defun wf5-claim-init-state-handler ()
  (labels
    ([parse (resp entity)
      (let* ([claim-id  (or (get resp "claim_id") (get entity "claim_id"))]
             [policy-id (or (get resp "policy_id") (get entity "policy_id")
                             (set-exception-business "missing policy_id"))]
             [sap       (or (get resp "sap") (sorted-map))])
        (when (nil? claim-id)
          (set-exception-business "missing claim_id"))
        (sorted-map
          "claim_id"  claim-id
          "policy_id" policy-id
          "sap"       sap
          "chain_to_wf5" (normalize-bool (get resp "chain_to_wf5") true)))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "claim_id"  (get parsed "claim_id")
        "policy_id" (get parsed "policy_id")
        "sap"       (get parsed "sap")
        "chain_to_wf5" (get parsed "chain_to_wf5"))]
     [create-events (entity parsed accessors)
      (vector)])
    (mk-state-handler
      :next            "WF5_CLAIM_STATE_AWAITING_APPROVAL"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf5-claim-awaiting-approval-handler ()
  (labels
    ([parse (resp entity) resp]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors) (or parsed (sorted-map))]
     [create-events (entity parsed accessors)
      (vector (wf5-mk-sap-store-payment-event entity
                 (or (get entity "sap") (sorted-map))))])
    (mk-state-handler
      :next            "WF5_CLAIM_STATE_SAP_PAID"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf5-claim-sap-paid-handler ()
  (labels
    ([parse (resp entity) (wf5-parse-sap-payment resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "sap_payment_txn_id" (get parsed "transaction_id")
        "sap_paid_amount"    (get parsed "amount")
        "sap_posting_ref"    (get parsed "posting_ref")
        "sap_status"         (get parsed "status"))]
     [create-events (entity parsed accessors) (vector)])
    (mk-state-handler
      :next            "WF5_CLAIM_STATE_DONE"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf5-claim-done-state-handler ()
  (labels
    ([parse (resp entity) (if (nil? resp) (sorted-map) (parse-generic-resp resp))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors) ()]
     [create-events (entity parsed accessors) ()])
    (mk-state-handler
      :next            "WF5_CLAIM_STATE_DONE"
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

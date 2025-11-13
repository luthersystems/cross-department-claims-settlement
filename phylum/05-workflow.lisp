
(in-package 'sandbox)

;; -----------------------------------------------------------------------------
;; Helper constructors and parsers for Workflow 5 (SAP payment acknowledgement)
;; -----------------------------------------------------------------------------

(defun wf5-mk-sap-store-payment-event (entity sap-payload)
  (let* ([payment-id   (or (get sap-payload "payment_id") *wf5-default-sap-payment-id*)]
         [invoice-id   (or (get sap-payload "invoice_id") *wf5-default-sap-invoice-id*)]
         [reference    (or (get sap-payload "reference") *wf5-default-sap-reference*)]
         [vendor-id    (or (get sap-payload "vendor_id") *wf5-default-sap-vendor-id*)]
         [amount       (or (get sap-payload "amount") *wf5-default-sap-amount*)]
         [currency     (or (get sap-payload "currency") *wf5-default-sap-currency*)]
         [method       (or (get sap-payload "payment_method") *wf5-default-sap-payment-method*)]
         [payment-date (or (get sap-payload "payment_date") *wf5-default-sap-payment-date*)]
         [status       (or (get sap-payload "status") *wf5-default-sap-status*)]
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
      "transaction_id" (or (get payment "transaction_id") *wf5-default-sap-transaction-id*)
      "amount"         (or (get payment "amount") *wf5-default-sap-amount*)
      "posting_ref"    (or (get payment "posting_ref") *wf5-default-sap-posting-ref*)
      "status"         (or (get payment "status") *wf5-default-sap-posted-status*))))

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
          "sap"       sap))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "claim_id"  (get parsed "claim_id")
        "policy_id" (get parsed "policy_id")
        "sap"       (get parsed "sap"))]
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

;; build-event moved to substr_generic_parser.lisp

(in-package 'sandbox)

;; -----------------------------------------------------------------------------
;; Parsers and Event Creators for Workflow 5 (SAP payment acknowledgement)
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


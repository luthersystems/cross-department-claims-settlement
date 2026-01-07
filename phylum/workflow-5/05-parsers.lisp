(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; Parsers and Event Creators for Workflow 5 (D365FO payment journal + SAP HANA recording)
;; -----------------------------------------------------------------------------

;; Create D365FO payment journal event
(defun wf5-mk-d365fo-payment-event (entity sap-payload accessors)
  (cc:infof (sorted-map
              "entity" entity
              "sap-payload" sap-payload)
            "wf5-mk-d365fo-payment-event: creating D365FO payment journal event")
  (let* ([payment-id   (or (get sap-payload "payment_id") *wf5-default-sap-payment-id*)]
         [invoice-id   (or (get sap-payload "invoice_id") *wf5-default-sap-invoice-id*)]
         [reference    (or (get sap-payload "reference") *wf5-default-sap-reference*)]
         [vendor-id    (or (get sap-payload "vendor_id") *wf5-default-sap-vendor-id*)]
         [amount       (or (get sap-payload "amount") *wf5-default-sap-amount*)]
         [currency     (or (get sap-payload "currency") *wf5-default-sap-currency*)]
         [method       (or (get sap-payload "payment_method") *wf5-default-sap-payment-method*)]
         [payment-date (or (get sap-payload "payment_date") *wf5-default-sap-payment-date*)]
         [status       (or (get sap-payload "status") *wf5-default-sap-status*)]
         ;; Build D365FO JournalNames entity data
         ;; Map payment data to D365FO journal fields
         [journal-name (format-string "{}-AP-PAY" (or vendor-id "DAT"))]
         [journal-description (format-string "AP payments - {} - {}" reference invoice-id)]
         [d365fo-data (sorted-map
                        "dataAreaId" "DAT"
                        "Name" journal-name
                        "Type" "Payment"
                        "Description" journal-description
                        "VoucherSeriesCode" "VOUCHER")]
         [req (mk-connector-req
                (sorted-map
                  "kind" "KIND_D365_FO"
                  "operation" "d365fo_create_entity_record"
                  "args" (sorted-map
                           "entity_name" "JournalNames"
                           "data" d365fo-data
                           "return_record" true
                           "profile" "default")))])
    (build-event entity req "create d365fo payment journal" "D365FO" (get accessors :entity-id))))

;; Create SAP HANA recording event (after D365FO payment is created)
(defun wf5-mk-sap-record-payment-event (entity d365fo-record sap-payload accessors)
  (let* ([payment-id   (or (get sap-payload "payment_id") *wf5-default-sap-payment-id*)]
         [invoice-id   (or (get sap-payload "invoice_id") *wf5-default-sap-invoice-id*)]
         [reference    (or (get sap-payload "reference") *wf5-default-sap-reference*)]
         [vendor-id    (or (get sap-payload "vendor_id") *wf5-default-sap-vendor-id*)]
         [amount       (or (get sap-payload "amount") *wf5-default-sap-amount*)]
         [currency     (or (get sap-payload "currency") *wf5-default-sap-currency*)]
         [method       (or (get sap-payload "payment_method") *wf5-default-sap-payment-method*)]
         [payment-date (or (get sap-payload "payment_date") *wf5-default-sap-payment-date*)]
         [status       (or (get sap-payload "status") *wf5-default-sap-status*)]
         ;; Extract D365FO transaction ID from the record
         [d365fo-txn-id (or (get d365fo-record "RecId")
                           (get d365fo-record "Name")
                           (get d365fo-record "transaction_id"))]
         ;; Build SAP HANA INSERT query to record the payment
         [query (format-string
                  "INSERT INTO PAYMENTS_STAGING (PAYMENT_ID, INVOICE_ID, REFERENCE, VENDOR_ID, AMOUNT, CURRENCY, PAYMENT_METHOD, PAYMENT_DATE, STATUS, D365FO_TXN_ID) VALUES ('{}', '{}', '{}', '{}', {}, '{}', '{}', '{}', '{}', '{}');"
                  payment-id invoice-id reference vendor-id amount currency method payment-date status d365fo-txn-id)]
         [req (mk-connector-req
                (sorted-map
                  "kind" "KIND_SAP_HANA"
                  "operation" "hana_execute_query"
                  "args" (sorted-map "query" query)))])
    (build-event entity req "record payment in sap hana" *connector-id-sap* (get accessors :entity-id))))

;; Parse D365FO payment journal response
(defun wf5-parse-d365fo-payment (resp)
  (let* ([parsed (parse-generic-resp resp)]
         ;; D365FO returns the created entity record
         [record (or (get parsed "record") (get parsed "data") parsed)]
         ;; Extract transaction ID from D365FO response (could be in RecId or Name field)
         [transaction-id (or (get record "RecId") 
                            (get record "Name")
                            (get record "transaction_id")
                            *wf5-default-sap-transaction-id*)]
         ;; Extract amount if available, otherwise use default
         [amount (or (get record "amount") *wf5-default-sap-amount*)]
         ;; Extract posting reference (could be VoucherSeriesCode or Name)
         [posting-ref (or (get record "VoucherSeriesCode")
                         (get record "Name")
                         (get record "posting_ref")
                         *wf5-default-sap-posting-ref*)]
         ;; Status is typically "created" or "posted" for D365FO
         [status (or (get record "status") "posted" *wf5-default-sap-posted-status*)])
    (sorted-map
      "d365fo_record" record
      "transaction_id" transaction-id
      "amount"         amount
      "posting_ref"    posting-ref
      "status"         status)))

;; Parse SAP HANA payment recording response
(defun wf5-parse-sap-payment (resp)
  (let* ([parsed (parse-generic-resp resp)]
         ;; SAP HANA returns payment data
         [payment (or (get parsed "payment") parsed)])
    (sorted-map
      "transaction_id" (or (get payment "transaction_id") *wf5-default-sap-transaction-id*)
      "amount"         (or (get payment "amount") *wf5-default-sap-amount*)
      "posting_ref"    (or (get payment "posting_ref") *wf5-default-sap-posting-ref*)
      "status"         (or (get payment "status") *wf5-default-sap-posted-status*))))

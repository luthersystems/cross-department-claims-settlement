;; Copyright © 2025 Luther Systems, Ltd. All right reserved.
;; Unit tests for Workflow 5: SAP Payment Acknowledgement

(in-package 'cdcs)
(use-package 'testing)

;; Test helper: Create a test entity
(defun mk-test-entity-wf5 ()
  (sorted-map
   "claim_id" "CLM-4567"
   "policy_id" "POL-8872"
   "invoice_id" "INV-789"
   "payment_id" "PAY-12345"))

;; Test helper: Create mock SAP response
(defun mk-test-sap-response ()
  (sorted-map
   "request_id" "req-sap-123"
   "response" (sorted-map
                "generic" (sorted-map
                           "text" "{\"payment\":{\"transaction_id\":\"TXN-789\",\"amount\":2500.00,\"posting_ref\":\"POST-REF-123\",\"status\":\"posted\"}}"))))

;; =============================
;; Test: Parse SAP Payment Response
;; =============================
(test "wf5-parse-sap-payment"
      (let* ([resp (mk-test-sap-response)]
             [parsed (wf5-parse-sap-payment resp)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "transaction_id") "TXN-789"))
        (assert (= (get parsed "amount") 2500.00))
        (assert (equal? (get parsed "posting_ref") "POST-REF-123"))
        (assert (equal? (get parsed "status") "posted"))))

;; =============================
;; Test: Create SAP Event
;; =============================
(test "wf5-mk-sap-record-payment-event"
      (let* ([entity (mk-test-entity-wf5)]
             [d365fo-record (sorted-map "RecId" "D365FO-12345" "Name" "JOURNAL-001")]
             [sap-payload (sorted-map
                           "payment_id" "PAY-12345"
                           "invoice_id" "INV-789"
                           "reference" "CLM-4567"
                           "vendor_id" "VENDOR-001"
                           "amount" 2500.00
                           "currency" "GBP"
                           "payment_method" "BANK_TRANSFER"
                           "payment_date" "2024-01-20"
                           "status" "pending")]
             [event (wf5-mk-sap-record-payment-event entity d365fo-record sap-payload (sorted-map :entity-id (get entity "claim_id")))])
        (assert (not (nil? event)))
        (assert (equal? (get event "oid") "CLM-4567"))
        (assert (equal? (get event "sys") "sap"))
        (assert (equal? (get event "eng") "record payment in sap hana"))))

;; =============================
;; Test: Init State Handler Parse
;; =============================
(test "wf5-claim-init-state-handler-parse"
      (let* ([handler (wf5-claim-init-state-handler)]
             [receive-fn (get handler :receive)]
             [resp (sorted-map)]
             [entity (sorted-map "claim_id" "CLM-4567")]
             [parsed (funcall receive-fn resp entity (sorted-map))])
        (assert (not (nil? parsed)))
        ;; Init handler receives claim_id for validation
        (assert (equal? (get parsed "claim_id") "CLM-4567"))
        (assert (equal? (length (keys parsed)) 1))))

;; =============================
;; Test: SAP Payment Stored State Handler
;; =============================
(test "wf5-sap-payment-stored-state-handler"
      (let* ([handler (wf5-claim-sap-paid-handler)]
             [receive-fn (get handler :receive)]
             [store-durable-fn (get handler :store-durable)]
             [validate-fn (get handler :validate)]
             [resp (mk-test-sap-response)]
             [entity (mk-test-entity-wf5)]
             [received (funcall receive-fn resp entity (sorted-map))]
             [validated (funcall validate-fn received entity (sorted-map))]
             [durable (funcall store-durable-fn entity validated (sorted-map))])
        (assert (not (nil? validated)))
        (assert (not (nil? durable)))
        (assert (equal? (get durable "sap_payment_txn_id") "TXN-789"))
        (assert (equal? (get durable "sap_status") "posted"))))


;; =============================
;; Test: SAP insert quotes strings and refuses a non-numeric amount
;; =============================
;; The D365FO record comes from a vendor response, so its values must not be
;; able to change the INSERT statement.
(test "wf5-mk-sap-record-payment-event-quotes-values"
      (let* ([entity (mk-test-entity-wf5)]
             [acc (sorted-map :entity-id (get entity "claim_id"))]
             [d365fo-record (sorted-map "RecId" "D365'); DELETE FROM PAYMENTS_STAGING; --")]
             [query-for (lambda (amount)
                          (get (get (get (get (wf5-mk-sap-record-payment-event
                                                entity d365fo-record (sorted-map "amount" amount) acc)
                                              "req") "generic") "arguments") "query"))]
             [expected-for (lambda (amount-text)
                             (format-string
                               "INSERT INTO PAYMENTS_STAGING (PAYMENT_ID, INVOICE_ID, REFERENCE, VENDOR_ID, AMOUNT, CURRENCY, PAYMENT_METHOD, PAYMENT_DATE, STATUS, D365FO_TXN_ID) VALUES ('PAYM-002', 'INV-1002', 'Batch-Nov-01', 'VEND-001', {}, 'USD', 'EFT', '2025-11-06', 'PENDING', 'D365''); DELETE FROM PAYMENTS_STAGING; --');"
                               amount-text))])
        (assert (equal? (funcall query-for 10) (funcall expected-for "10")))
        ;; A decimal string is kept as is; an integral float has no exponent.
        (assert (equal? (funcall query-for "2500.00") (funcall expected-for "2500.00")))
        (assert (equal? (funcall query-for 10000000.0) (funcall expected-for "10000000")))
        ;; Anything that is not a plain decimal is refused with a business
        ;; exception, including a float that elps prints in exponent form.
        (map ()
             (lambda (amount)
               (let ([raised (handler-bind ([set-exception-error (lambda (_ e) true)])
                               (funcall query-for amount)
                               false)])
                 (assert raised)))
             (list "1); DROP TABLE X; --" 2500000.5))))

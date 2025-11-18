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
             [event (wf5-mk-sap-record-payment-event entity d365fo-record sap-payload)])
        (assert (not (nil? event)))
        (assert (equal? (get event "oid") "CLM-4567"))
        (assert (equal? (get event "sys") "SAP"))
        (assert (equal? (get event "eng") "record payment in sap hana"))))

;; =============================
;; Test: Init State Handler Parse
;; =============================
(test "wf5-claim-init-state-handler-parse"
      (let* ([handler (wf5-claim-init-state-handler)]
             [parse-fn (get handler :parse)]
             [resp (sorted-map)]
             [entity (sorted-map "claim_id" "CLM-4567")]
             [parsed (funcall parse-fn resp entity)])
        (assert (not (nil? parsed)))
        ;; Init handler validates claim_id exists but doesn't include it in parsed
        ;; claim_id is managed by entity manager, not persisted in stage functions
        (assert (nil? (get parsed "claim_id")))
        (assert (equal? (length (keys parsed)) 0))))

;; =============================
;; Test: SAP Payment Stored State Handler
;; =============================
(test "wf5-sap-payment-stored-state-handler"
      (let* ([handler (wf5-claim-sap-paid-handler)]
             [parse-fn (get handler :parse)]
             [stage-durable-fn (get handler :stage-durable)]
             [resp (mk-test-sap-response)]
             [entity (mk-test-entity-wf5)]
             [parsed (parse-fn resp entity)]
             [durable (stage-durable-fn entity parsed (sorted-map))])
        (assert (not (nil? parsed)))
        (assert (not (nil? durable)))
        (assert (equal? (get durable "sap_payment_txn_id") "TXN-789"))
        (assert (equal? (get durable "sap_status") "posted"))))


;; Copyright © 2025 Luther Systems, Ltd. All right reserved.
;; Unit tests for Workflow 3: Invoice Processing (eSignature → Salesforce → Email)

(in-package 'cdcs)
(use-package 'testing)

;; Test helper: Create a test entity
(defun mk-test-entity-wf3 ()
  (sorted-map
   "claim_id" "CLM-4567"
   "policy_id" "POL-8872"
   "amount" "2500.00"
   "signer_name" "John Doe"
   "signer_email" "john.doe@example.com"
   "originator_name" "Finance Department"
   "recipient_name" "Accounts Payable"
   "issue_date" "2024-01-15"))

;; Test helper: Create mock eSignature response
(defun mk-test-esignature-response ()
  (sorted-map
   "request_id" "req-esig-123"
   "response" (sorted-map
                "generic" (sorted-map
                           "text" "{\"data\":{\"data\":{\"contract\":{\"id\":\"contract-abc123\",\"status\":\"sent\",\"signers\":[{\"id\":\"signer-1\",\"name\":\"John Doe\",\"email\":\"john.doe@example.com\",\"sign_page_url\":\"https://esign.example.com/sign/abc123\"}]}}}}"))))

;; Test helper: Create mock Salesforce response
(defun mk-test-salesforce-response ()
  (sorted-map
   "request_id" "req-sf-123"
   "response" (sorted-map
                "generic" (sorted-map
                           "text" "{\"id\":\"a0X5g000000ABC123\",\"success\":true,\"errors\":[]}"))))

;; Test helper: Create mock SMTP response
(defun mk-test-smtp-response ()
  (sorted-map
   "request_id" "req-smtp-123"
   "response" (sorted-map
                "generic" (sorted-map
                           "text" "{\"status\":\"sent\",\"message_id\":\"msg-123\"}"))))

;; =============================
;; Test: Parse eSignature Response
;; =============================
(test "parse-esignature-create-contract"
      (let* ([resp (mk-test-esignature-response)]
             [parsed (parse-esignature-create-contract resp)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "contract_id") "contract-abc123"))
        (assert (equal? (get parsed "contract_status") "sent"))
        (assert (equal? (get parsed "sign_page_url") "https://esign.example.com/sign/abc123"))))

;; =============================
;; Test: Parse Salesforce Response
;; =============================
(test "parse-salesforce-create-record"
      (let* ([resp (mk-test-salesforce-response)]
             [parsed (parse-salesforce-create-record resp)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "sf_record_id") "a0X5g000000ABC123"))))

;; =============================
;; Test: Parse SMTP Response
;; =============================
(test "parse-smtp-send"
      (let* ([resp (mk-test-smtp-response)]
             [parsed (parse-smtp-send resp)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "status") "sent"))))

;; =============================
;; Test: Create eSignature Event
;; =============================
(test "mk-esignature-create-contract-event"
      (let* ([entity (mk-test-entity-wf3)]
             [event (mk-esignature-create-contract-event entity (sorted-map :entity-id (get entity "claim_id")))])
        (assert (not (nil? event)))
        (assert (equal? (get event "oid") "CLM-4567"))
        (assert (equal? (get event "sys") "esignature"))
        (assert (equal? (get event "eng") "create invoice contract"))
        (assert (not (nil? (get event "req"))))))

;; =============================
;; Test: Create Salesforce Event
;; =============================
(test "mk-salesforce-create-invoice-event"
      (let* ([entity (mk-test-entity-wf3)]
             [args (sorted-map
                    "contract_id" "contract-abc123"
                    "sign_page_url" "https://esign.example.com/sign/abc123")]
             [event (mk-salesforce-create-invoice-event entity args (sorted-map :entity-id (get entity "claim_id")))])
        (assert (not (nil? event)))
        (assert (equal? (get event "oid") "CLM-4567"))
        (assert (equal? (get event "sys") "salesforce"))
        (assert (equal? (get event "eng") "create sf invoice"))))

;; =============================
;; Test: Init State Handler Parse
;; =============================
(test "wf3-invoice-init-state-handler-parse"
      (let* ([handler (wf3-invoice-init-state-handler)]
             [parse-fn (get handler :parse)]
             [resp (sorted-map
                    "claim_id" "CLM-4567"
                    "invoice_amount" "2500.00"
                    "signer_name" "John Doe"
                    "signer_email" "john.doe@example.com"
                    "originator_name" "Finance Department"
                    "recipient_name" "Accounts Payable"
                    "issue_date" "2024-01-15")]
             [entity (sorted-map)]
             [parsed (funcall parse-fn resp entity)])
        (assert (not (nil? parsed)))
        ;; claim_id should NOT be in parsed - it's managed by entity manager, not persisted
        (assert (nil? (get parsed "claim_id")))
        (assert (equal? (get parsed "amount") "2500.00"))
        (assert (equal? (get parsed "signer_name") "John Doe"))
        (assert (equal? (get parsed "signer_email") "john.doe@example.com"))))

;; =============================
;; Test: eSignature Contract Created State Handler
;; =============================
(test "wf3-esignature-contract-created-state-handler"
      (let* ([handler (wf3-invoice-esig-created-state-handler)]
             [parse-fn (get handler :parse)]
             [stage-durable-fn (get handler :stage-durable)]
             [resp (mk-test-esignature-response)]
             [entity (mk-test-entity-wf3)]
             [parsed (parse-fn resp entity)]
             [durable (stage-durable-fn entity parsed (sorted-map))])
        (assert (not (nil? parsed)))
        (assert (not (nil? durable)))
        (assert (equal? (get durable "esign_contract_id") "contract-abc123"))
        (assert (equal? (get durable "esign_status") "sent"))
        (assert (equal? (get durable "esign_sign_page_url") "https://esign.example.com/sign/abc123"))))

;; =============================
;; Test: Salesforce Invoice Created State Handler
;; =============================
(test "wf3-salesforce-invoice-created-state-handler"
      (let* ([handler (wf3-invoice-sf-synced-state-handler)]
             [parse-fn (get handler :parse)]
             [stage-durable-fn (get handler :stage-durable)]
             [resp (mk-test-salesforce-response)]
             [entity (mk-test-entity-wf3)]
             [parsed (parse-fn resp entity)]
             [durable (stage-durable-fn entity parsed (sorted-map))])
        (assert (not (nil? parsed)))
        (assert (not (nil? durable)))
        (assert (equal? (get durable "sf_record_id") "a0X5g000000ABC123"))))

;; =============================
;; Test: Email Dispatched State Handler
;; =============================
(test "wf3-invoice-email-dispatched-state-handler"
      (let* ([handler (wf3-invoice-email-dispatched-state-handler)]
             [parse-fn (get handler :parse)]
             [stage-durable-fn (get handler :stage-durable)]
             [resp (mk-test-smtp-response)]
             [entity (mk-test-entity-wf3)]
             [parsed (parse-fn resp entity)]
             [durable (stage-durable-fn entity parsed (sorted-map))])
        (assert (not (nil? parsed)))
        (assert (not (nil? durable)))
        (assert (equal? (get durable "email_dispatched") true)
                "Email dispatched flag should be set")))

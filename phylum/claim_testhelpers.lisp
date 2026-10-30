;; Copyright © 2025 Luther Systems, Ltd. All right reserved.
;; Shared helpers for the claim tests: a start request, the connector replies
;; the mocked hub gives (fabric/connectorhub.yaml), and a driver that answers
;; each step in order.
(in-package 'cdcs)
(use-package 'testing)

(defun test-claim-request ()
  (sorted-map "policy_id"          "POL-8872"
              "guidewire_claim_id" "GW-1001"
              "invoice_amount"     "25000.00"
              "signer_name"        "Jack Clarke"
              "signer_email"       "jack.clarke@example.com"))

;; "Claim ID: CLM-4567\nDate: 2025-11-12\nSigner: John Doe\nVerified: Yes"
(set 'test-id-document-line "Q2xhaW0gSUQ6IENMTS00NTY3CkRhdGU6IDIwMjUtMTEtMTIKU2lnbmVyOiBKb2huIERvZQpWZXJpZmllZDogWWVz")

;; The reply each connector step gets in the demo, by await label.
(set 'test-replies
     (sorted-map
       "oracle-claim"        (sorted-map "rows" (vector (sorted-map
                                                          "CLAIM_ID" "CLM-4567" "POLICY_ID" "POL-8872"
                                                          "AMOUNT" 2500.0 "STATUS" "UnderReview"
                                                          "CLAIMANT_FIRST_NAME" "John" "CLAIMANT_LAST_NAME" "Doe"
                                                          "CLAIMANT_DOB" "1980-05-15"
                                                          "CLAIMANT_ADDRESS" "123 Main Street, London, SW1A 1AA"
                                                          "CLAIMANT_NATIONAL_ID" "AB123456C")))
       "equifax-screening"   (sorted-map "equifax" (sorted-map "entity_screening_response"
                                                     (sorted-map "status" "Pass" "pstatus_det" "Clear"
                                                                 "hit_value_pep" 0 "hit_value_emb" 0
                                                                 "list_matches" (vector))))
       "teams-thread"        (sorted-map "thread_id" "thread-12345" "message_id" "msg-12345" "status" "created")
       "guidewire-claim"     (sorted-map "claim_id" "GW-1001" "status" "UnderReview" "handler" "ajones")
       "policy-check"        (vector (sorted-map "POLICY_ID" "POL-8872" "STATUS" "Active" "COVERAGE_LIMIT" "20000.00"))
       "id-document"         (sorted-map "type" "text" "content" (vector test-id-document-line) "line_count" 4)
       "guidewire-approval"  (sorted-map "claim_id" "GW-1001" "approval" "ApprovedForSettlement")
       "esignature-contract" (sorted-map "data" (sorted-map "data" (sorted-map "contract"
                                                  (sorted-map "id" "contract-abc123" "status" "pending"
                                                              "signers" (vector (sorted-map "sign_page_url" "https://esign.example.com/sign/abc123"))))))
       "salesforce-invoice"  (sorted-map "id" "a0X5g000000XYZ1" "success" true)
       "invoice-email"       (sorted-map "message_id" "email-msg-12345" "status" "sent")
       "zoho-invoice"        (sorted-map "invoice" (sorted-map "invoice_id" "INV-10001" "invoice_number" "1234567000001" "total" 1250.0))
       "settlement-document" (sorted-map "type" "text" "content" (vector test-id-document-line) "line_count" 4)
       "servicenow-incident" (sorted-map "result" (sorted-map "sys_id" "abc123def456" "number" "INC0010001"))
       "payment-notice"      (sorted-map "thread_id" "thread-12345" "status" "updated")
       "d365fo-journal"      (sorted-map "record" (sorted-map "RecId" "5637144576" "Name" "DAT-AP-PAY"))
       "sap-payment"         (sorted-map "payment" (sorted-map "transaction_id" "SAP-TXN-1001" "status" "posted"))))

(defun start-test-claim (key &optional req)
  (flow-test:as "Org1MSP")
  (get (flow-test:start 'claim key (or req (test-claim-request))) "run_id"))

(defun claim-label (run) (get (flow-test:run 'claim run) "label"))
(defun claim-state (run) (get (flow-test:run 'claim run) "state"))
(defun claim-result (run) (get (flow-test:run 'claim run) "result"))
(defun claim-error (run) (get (flow-test:run 'claim run) "error"))

;; Answer connector steps with test-replies until the run waits at stop-label,
;; waits for an input, or ends.
(defun answer-connectors (run &optional stop-label)
  (flow-test:as "Org1MSP")
  (labels ([step ()
             (let ([label (claim-label run)])
               (when (and (equal? (claim-state run) "waiting")
                          (not (equal? label stop-label))
                          (key? test-replies label))
                 (flow-test:reply 'claim run (get test-replies label))
                 (step)))])
    (step))
  (claim-label run))

;; Drive a fresh claim to the contract-signed input.
(defun claim-at-contract-signed (key)
  (let ([run (start-test-claim key)])
    (assert-string= "contract-signed" (answer-connectors run))
    run))

;; Drive a fresh claim to the payment-status input.
(defun claim-at-payment-status (key)
  (let ([run (claim-at-contract-signed key)])
    (flow-test:input 'claim 'contract-signed run (sorted-map "signed_by" "jack.clarke@example.com"))
    (assert-string= "payment-approved" (answer-connectors run))
    (flow-test:input 'claim 'payment-approved run (sorted-map "signed_by" "payments@example.com"))
    (assert-string= "payment-status" (claim-label run))
    run))

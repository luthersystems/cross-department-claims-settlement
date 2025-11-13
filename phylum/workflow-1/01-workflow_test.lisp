;; Copyright © 2025 Luther Systems, Ltd. All right reserved.
;; Unit tests for Workflow 1: Claim Initiation (Oracle → Equifax → Teams)

(in-package 'cdcs)
(use-package 'testing)

;; Test helper: Create a test entity
(defun mk-test-entity-wf1 ()
  (sorted-map
   "claim_id" "CLM-4567"
   "policy_id" "POL-8872"
   "amount" 2500.00
   "status" "UnderReview"))

;; Test helper: Create mock Oracle response
(defun mk-test-oracle-response ()
  (sorted-map
   "request_id" "req-oracle-123"
   "response" (sorted-map
                "generic" (sorted-map
                           "text" "{\"rows\":[{\"CLAIM_ID\":\"CLM-4567\",\"POLICY_ID\":\"POL-8872\",\"AMOUNT\":2500.00,\"STATUS\":\"UnderReview\",\"CLAIMANT_FIRST_NAME\":\"John\",\"CLAIMANT_LAST_NAME\":\"Doe\",\"CLAIMANT_DOB\":\"1980-05-15\",\"CLAIMANT_ADDRESS\":\"123 Main Street, London, SW1A 1AA\",\"CLAIMANT_NATIONAL_ID\":\"AB123456C\"}]}"))))

;; Test helper: Create mock Equifax response
(defun mk-test-equifax-response ()
  (sorted-map
   "request_id" "req-equifax-123"
   "response" (sorted-map
                "generic" (sorted-map
                           "text" "{\"equifax\":{\"entity_screening_response\":{\"entity_id\":\"CLM-4567\",\"status\":\"Pass\",\"comment\":\"No matches found\",\"hit_value_emb\":0,\"hit_value_pep\":0,\"pstatus_det\":\"Clear\",\"list_matches\":[]}}}"))))

;; =============================
;; Test: Parse Oracle Response
;; =============================
(test "parse-oracle-get-claim-response"
      (let* ([resp (mk-test-oracle-response)]
             [parsed (parse-oracle-get-claim-response resp)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "claim_id") "CLM-4567"))
        (assert (equal? (get parsed "policy_id") "POL-8872"))
        (assert (= (get parsed "amount") 2500.00))
        (assert (not (nil? (get parsed "claimant"))))
        (assert (equal? (get (get parsed "claimant") "first_name") "John"))))

;; =============================
;; Test: Parse Equifax Response
;; =============================
(test "parse-equifax-verify-response"
      (let* ([resp (mk-test-equifax-response)]
             [parsed (parse-equifax-verify-response resp)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "entity_id") "CLM-4567"))
        (assert (equal? (get parsed "status") "Pass"))
        (assert (= (get parsed "hit_value_pep") 0))
        (assert (= (get parsed "hit_value_emb") 0))))

;; =============================
;; Test: Validate Equifax Response
;; =============================
(test "validate-equifax-response"
      (let* ([parsed (sorted-map
                      "status" "Pass"
                      "hit_value_pep" 0
                      "hit_value_emb" 0)]
             [validation (validate-equifax-response parsed)])
        (assert (equal? (get validation "valid") true))
        (assert (not (nil? (get validation "reason"))))))

;; =============================
;; Test: Create Oracle Event
;; =============================
(test "mk-oracle-get-claim-event"
      (let* ([entity (mk-test-entity-wf1)]
             [event (mk-oracle-get-claim-event entity "POL-8872")])
        (assert (not (nil? event)))
        (assert (equal? (get event "oid") "CLM-4567"))
        (assert (equal? (get event "sys") "ORACLE"))
        (assert (equal? (get event "eng") "get claim"))))

;; =============================
;; Test: Create Equifax Event
;; =============================
(test "mk-equifax-verify-event"
      (let* ([entity (mk-test-entity-wf1)]
             [claimant (sorted-map
                        "first_name" "John"
                        "last_name" "Doe"
                        "dob" "1980-05-15"
                        "address" "123 Main Street"
                        "national_id" "AB123456C")]
             [event (mk-equifax-verify-event entity claimant)])
        (assert (not (nil? event)))
        (assert (equal? (get event "oid") "CLM-4567"))
        (assert (equal? (get event "sys") "EQUIFAX"))
        (assert (equal? (get event "eng") "verify claimant"))))

;; =============================
;; Test: Init State Handler Parse
;; =============================
(test "wf1-claim-init-state-handler-parse"
      (let* ([handler (wf1-claim-init-state-handler)]
             [parse-fn (get handler :parse)]
             [resp (sorted-map
                    "policy_id" "POL-8872"
                    "gw_claim_id" "GW-CLM-12345"
                    "signer_email" "john@example.com"
                    "signer_name" "John Doe"
                    "invoice_amount" "2500.00"
                    "originator_name" "Finance"
                    "recipient_name" "Accounts"
                    "issue_date" "2024-01-15")]
             [entity (sorted-map)]
             [parsed (funcall parse-fn resp entity)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "policy_id") "POL-8872"))
        (assert (equal? (get parsed "gw_claim_id") "GW-CLM-12345"))
        (assert (equal? (get parsed "signer_email") "john@example.com"))))

;; =============================
;; Test: Oracle Details Retrieved State Handler
;; =============================
(test "wf1-claim-oracle-details-retrieved-state-handler"
      (let* ([handler (wf1-claim-oracle-details-retrieved-state-handler)]
             [parse-fn (get handler :parse)]
             [stage-durable-fn (get handler :stage-durable)]
             [resp (mk-test-oracle-response)]
             [entity (mk-test-entity-wf1)]
             [parsed (parse-fn resp entity)]
             [durable (stage-durable-fn entity parsed (sorted-map))])
        (assert (not (nil? parsed)))
        (assert (not (nil? durable)))
        (assert (equal? (get durable "oracle_claim_id") "claim:CLM-4567"))
        (assert (= (get durable "amount") 2500.00))))

;; =============================
;; Test: Equifax Verified State Handler
;; =============================
(test "wf1-claim-equifax-verified-state-handler"
      (let* ([handler (wf1-claim-equifax-verified-state-handler)]
             [parse-fn (get handler :parse)]
             [stage-durable-fn (get handler :stage-durable)]
             [resp (mk-test-equifax-response)]
             [entity (mk-test-entity-wf1)]
             [parsed (parse-fn resp entity)]
             [durable (stage-durable-fn entity parsed (sorted-map))])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "status") "Pass"))
        (assert (not (nil? durable)))
        (assert (equal? (get durable "equifax_status") "Pass"))
        (assert (= (get durable "equifax_hit_value_pep") 0))))


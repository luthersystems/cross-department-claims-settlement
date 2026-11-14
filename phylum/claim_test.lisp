;; Copyright © 2025 Luther Systems, Ltd. All right reserved.
;; Flow tests of the claim defflow (claim.lisp): each run is driven through
;; the generated endpoints with the replies the mocked hub gives.
(in-package 'cdcs)
(use-package 'testing)

(test "a claim runs from the Oracle lookup to the SAP payment record"
  (let ([run (claim-at-payment-status "happy")])
    (flow-test:input 'claim 'payment-status run (sorted-map "payment_id" "PAY-1" "status" "Approved"))
    (assert-string= "d365fo-journal" (claim-label run))
    (answer-connectors run)
    (assert-string= "done" (claim-state run))
    (let ([result (claim-result run)])
      (assert-string= "paid" (get result "decision"))
      (assert-string= run (get result "claim_id"))
      (assert-string= "CLM-4567" (get result "oracle_claim_id"))
      (assert-string= "passed" (get result "screening"))
      (assert-string= "contract-abc123" (get result "esign_contract_id"))
      (assert-string= "jack.clarke@example.com" (get result "contract_signed_by"))
      (assert-string= "payments@example.com" (get result "payment_approved_by"))
      (assert-string= "PAY-1" (get result "payment_id"))
      (assert-string= "5637144576" (get result "d365fo_txn_id"))
      (assert-string= "SAP-TXN-1001" (get result "sap_txn"))
      (assert-string= "settlement-CLM-4567.txt" (get (get result "settlement_document") "file")))))

(test "claim_get exposes the claim while the run waits"
  (let* ([run (start-test-claim "expose")]
         [claim (get (get (flow-test:run 'claim run) "vars") "claim")])
    (assert-string= "oracle-claim" (claim-label run))
    (assert-string= run (get claim "claim_id"))
    (assert-string= "POL-8872" (get claim "policy_id"))))

(test "a rejected payment ends the claim without posting it"
  (let ([run (claim-at-payment-status "rejected")])
    (flow-test:input 'claim 'payment-status run (sorted-map "payment_id" "PAY-2" "status" "rejected"))
    (assert-string= "done" (claim-state run))
    (assert-string= "payment rejected" (get (claim-result run) "decision"))
    (assert-nil (get (claim-result run) "sap_txn"))))

(test "a pending payment waits for the next status"
  (let ([run (claim-at-payment-status "pending")])
    (flow-test:input 'claim 'payment-status run (sorted-map "payment_id" "PAY-3" "status" "pending"))
    (assert-string= "payment-status" (claim-label run))
    (flow-test:input 'claim 'payment-status run (sorted-map "payment_id" "PAY-3" "status" "approved"))
    (assert-string= "d365fo-journal" (claim-label run))))

(test "a start request without the required fields writes no run"
  (flow-test:as "Org1MSP")
  (let ([rej (flow-test:rejection 'claim "start" "missing"
                                  (with-fields (test-claim-request) "signer_email" ""))])
    (assert-string= "start-rejected" (get rej "error"))
    (assert (string:contains? (get rej "message") "missing signer_email"))))

(test "a reply the next step cannot use fails the run with the reason"
  (let ([run (start-test-claim "no-policy")])
    (answer-connectors run "policy-check")
    (flow-test:reply 'claim run (vector))
    (assert-string= "failed" (claim-state run))
    (assert (string:contains? (json:dump-string (claim-error run)) "the policy is not active"))))

(test "an ID document for another claim fails the run"
  (let ([run (start-test-claim "wrong-id")])
    (answer-connectors run "id-document")
    (flow-test:reply 'claim run (id-document-reply "CLM-1"))
    (assert-string= "failed" (claim-state run))
    (assert (string:contains? (json:dump-string (claim-error run)) "does not name claim CLM-4567"))))

(test "an invoice above the claim amount fails the run before any write"
  (let ([run (start-test-claim "over-claim" (with-fields (test-claim-request) "invoice_amount" "2600.00"))])
    (answer-connectors run "oracle-claim")
    (flow-test:reply 'claim run (get test-replies "oracle-claim"))
    (assert-string= "failed" (claim-state run))
    (assert (string:contains? (json:dump-string (claim-error run))
                              "invoice_amount 2600.00 exceeds the Oracle claim amount 2500"))))

(test "an invoice above the coverage limit fails the run before the Guidewire approval"
  (let ([run (start-test-claim "over-limit")])
    (answer-connectors run "policy-check")
    (flow-test:reply 'claim run (vector (sorted-map "STATUS" "Active" "COVERAGE_LIMIT" "2000.00")))
    (assert-string= "failed" (claim-state run))
    (assert (string:contains? (json:dump-string (claim-error run))
                              "invoice_amount 2500.00 exceeds the policy's coverage limit 2000.00"))))

(test "a claim Guidewire rejected or closed fails the run"
  (map ()
       (lambda (status)
         (let ([run (start-test-claim (format-string "gw-{}" status))])
           (answer-connectors run "guidewire-claim")
           (flow-test:reply 'claim run (sorted-map "claim_id" "GW-1001" "status" status))
           (assert-string= "failed" (claim-state run))
           (assert (string:contains? (json:dump-string (claim-error run))
                                     (format-string "Guidewire claim status {} cannot be settled" status)))))
       (list "Rejected" "Closed")))

(test "a start that names the ID document as the settlement document writes no run"
  (flow-test:as "Org1MSP")
  (let ([rej (flow-test:rejection 'claim "start" "id-as-settlement"
                                  (with-fields (test-claim-request) "settlement_document_item_id"
                                               (get id-document-file "item_id")))])
    (assert-string= "start-rejected" (get rej "error"))))

(test "a connector error fails the run"
  (let ([run (start-test-claim "conn-error")])
    (flow-test:reply-error 'claim run "Oracle is down")
    (assert-string= "failed" (claim-state run))))

(test "a screening concern goes to Teams and the claim goes on"
  (let ([run (start-test-claim "flagged")])
    (answer-connectors run "equifax-screening")
    (flow-test:reply 'claim run (sorted-map "entity_screening_response"
                                            (sorted-map "pstatus_det" "Review" "hit_value_pep" 0 "hit_value_emb" 0)))
    (assert-string= "teams-thread" (claim-label run))
    (assert-string= "contract-signed" (answer-connectors run))))

(test "an input the run is not waiting for is refused"
  (let ([run (claim-at-contract-signed "early")])
    (assert-string= "not-waiting"
                    (get (flow-test:rejection 'claim "in:payment-status" run
                                              (sorted-map "payment_id" "PAY-4" "status" "approved"))
                         "error"))
    (flow-test:as "Org2MSP")
    (assert-string= "forbidden"
                    (get (flow-test:rejection 'claim "in:contract-signed" run (sorted-map "signed_by" "x"))
                         "error"))))

;; #39: a claim Oracle closed was settled because Guidewire said Open.
(test "a claim Oracle does not hold Open fails the run before any write"
  (let ([run (start-test-claim "oracle-closed")])
    (flow-test:reply 'claim run (sorted-map "rows" (vector (assoc (first (get (get test-replies "oracle-claim") "rows"))
                                                                 "STATUS" "Closed"))))
    (assert-string= "failed" (claim-state run))
    (assert (string:contains? (json:dump-string (claim-error run))
                              "Oracle claim CLM-4567 status Closed cannot be settled"))))

;; #39: two starts for one claim, with different request keys, could each
;; pay the whole claim.  Each run here is on its own Oracle claim and policy
;; so the amounts other tests settle do not count.
(defun settled-test-request (claim-id policy-id amount)
  (with-fields (test-claim-request) "oracle_claim_id" claim-id "policy_id" policy-id "invoice_amount" amount))

;; Answer every step up to the payment-status input, with the Oracle and
;; policy replies for the request's claim and policy.
(defun claim-to-payment-status (key req)
  (let ([run (start-test-claim key req)])
    (flow-test:as "Org1MSP")
    (flow-test:reply 'claim run (oracle-row "CLAIM_ID" (get req "oracle_claim_id") "POLICY_ID" (get req "policy_id")))
    (answer-connectors run "id-document")
    ;; The demo ID document names CLM-4567; this claim has its own id.
    (flow-test:reply 'claim run (id-document-reply (get req "oracle_claim_id")))
    (assert-string= "contract-signed" (answer-connectors run))
    (flow-test:input 'claim 'contract-signed run (sorted-map "signed_by" "jack.clarke@example.com"))
    (assert-string= "payment-approved" (answer-connectors run))
    (flow-test:input 'claim 'payment-approved run (sorted-map "signed_by" "payments@example.com"))
    (assert-string= "payment-status" (claim-label run))
    run))

(test "a second run for a claim may settle only what the first left"
  (let ([first-run (claim-to-payment-status "settle-1" (settled-test-request "CLM-S1" "POL-S1" "2000.00"))])
    (assert= 200000 (settled-cents "claim" "CLM-S1"))
    (assert= 200000 (settled-cents "policy" "POL-S1"))
    ;; The whole claim again is refused at the Oracle reply.
    (let ([again (start-test-claim "settle-2" (settled-test-request "CLM-S1" "POL-S1" "2500.00"))])
      (flow-test:reply 'claim again (oracle-row "CLAIM_ID" "CLM-S1" "POLICY_ID" "POL-S1"))
      (assert-string= "failed" (claim-state again))
      (assert (string:contains? (json:dump-string (claim-error again))
                                "invoice_amount 2500.00 with 2000.00 already settled exceeds the Oracle claim amount 2500")))
    ;; What is left may settle.
    (let ([rest-run (claim-to-payment-status "settle-3" (settled-test-request "CLM-S1" "POL-S1" "500.00"))])
      (assert= 250000 (settled-cents "claim" "CLM-S1"))
      (flow-test:input 'claim 'payment-status rest-run (sorted-map "payment_id" "PAY-S3" "status" "approved"))
      (answer-connectors rest-run)
      (assert-string= "paid" (get (claim-result rest-run) "decision")))
    (flow-test:input 'claim 'payment-status first-run (sorted-map "payment_id" "PAY-S1" "status" "approved"))
    (answer-connectors first-run)
    (assert-string= "paid" (get (claim-result first-run) "decision"))
    (assert= 250000 (settled-cents "claim" "CLM-S1"))))

(test "two runs in flight cannot both take the same claim amount"
  ;; Both pass the Oracle and policy readers before either reserves; the
  ;; second is refused when it reserves.
  (let* ([req (settled-test-request "CLM-S2" "POL-S2" "2000.00")]
         [a (start-test-claim "race-a" req)]
         [b (start-test-claim "race-b" req)])
    (map ()
         (lambda (run)
           (flow-test:reply 'claim run (oracle-row "CLAIM_ID" "CLM-S2" "POLICY_ID" "POL-S2"))
           (answer-connectors run "id-document")
           (flow-test:reply 'claim run (id-document-reply "CLM-S2"))
           (assert-string= "contract-signed" (answer-connectors run))
           (flow-test:input 'claim 'contract-signed run (sorted-map "signed_by" "jack.clarke@example.com"))
           (answer-connectors run "servicenow-incident"))
         (list a b))
    (flow-test:reply 'claim a (get test-replies "servicenow-incident"))
    (assert-string= "payment-notice" (claim-label a))
    (flow-test:reply 'claim b (get test-replies "servicenow-incident"))
    (assert-string= "failed" (claim-state b))
    (assert (string:contains? (json:dump-string (claim-error b))
                              "invoice_amount 2000.00 with 2000.00 already settled exceeds the Oracle claim amount 2500"))
    (assert= 200000 (settled-cents "claim" "CLM-S2"))))

(test "a rejected payment gives its amount back"
  (let ([run (claim-to-payment-status "settle-rejected" (settled-test-request "CLM-S3" "POL-S3" "2500.00"))])
    (assert= 250000 (settled-cents "claim" "CLM-S3"))
    (flow-test:input 'claim 'payment-status run (sorted-map "payment_id" "PAY-S4" "status" "rejected"))
    (assert-string= "payment rejected" (get (claim-result run) "decision"))
    (assert= 0 (settled-cents "claim" "CLM-S3"))
    (assert= 0 (settled-cents "policy" "POL-S3"))))

(test "the coverage limit counts every claim on the policy"
  (claim-to-payment-status "policy-1" (settled-test-request "CLM-S4" "POL-S4" "2500.00"))
  (let ([run (start-test-claim "policy-2" (settled-test-request "CLM-S5" "POL-S4" "2500.00"))])
    (flow-test:reply 'claim run (oracle-row "CLAIM_ID" "CLM-S5" "POLICY_ID" "POL-S4"))
    (answer-connectors run "policy-check")
    (flow-test:reply 'claim run (vector (sorted-map "STATUS" "Active" "COVERAGE_LIMIT" "4000.00")))
    (assert-string= "failed" (claim-state run))
    (assert (string:contains? (json:dump-string (claim-error run))
                              "invoice_amount 2500.00 with 2500.00 already settled exceeds the policy's coverage limit 4000.00"))))

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
    (flow-test:reply 'claim run (sorted-map "type" "text" "content" (vector (base64:encode "Claim ID: CLM-1")) "line_count" 1))
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

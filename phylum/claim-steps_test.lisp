;; Copyright © 2025 Luther Systems, Ltd. All right reserved.
;; Unit tests of the step builders and readers in claim-steps.lisp.  The
;; flow tests (claim_test.lisp) run them in order; these pin each one alone,
;; so a broken reader names itself.
(in-package 'cdcs)
(use-package 'testing)

(defun event-req (event) (get (get event "req") "generic"))
(defun event-args (event) (get (event-req event) "arguments"))

;; Call thunk and return the bad-reply message it raises, or nil.
(defun bad-reply-message (thunk)
  (handler-bind ([bad-reply (lambda (_c msg) msg)])
    (funcall thunk)
    ()))

(defun test-claim () (new-claim "run-1" (test-claim-request)))

(test "claim-request-problem names each missing field"
  (assert-nil (claim-request-problem (test-claim-request)))
  (assert-string= "missing policy_id, signer_email"
                  (claim-request-problem (with-fields (test-claim-request)
                                                      "policy_id" "  " "signer_email" ())))
  (assert-string= "missing policy_id, guidewire_claim_id, invoice_amount, signer_name, signer_email"
                  (claim-request-problem (sorted-map))))

(test "claim-request-problem needs a positive decimal invoice amount"
  ;; Inf, NaN, hex and exponents parse as floats, but SAP and Salesforce get
  ;; the text and Zoho the number, so they would not agree.
  (map ()
       (lambda (amount)
         (assert-string= (format-string "invoice_amount {} is not a positive decimal amount" amount)
                         (claim-request-problem (with-fields (test-claim-request) "invoice_amount" amount))))
       (list "abc" "0" "-5" "0.00" "Inf" "+Infinity" "NaN" "0x1p4" "1e3" " 12" "12." 12))
  (map ()
       (lambda (amount)
         (assert-nil (claim-request-problem (with-fields (test-claim-request) "invoice_amount" amount))))
       (list "12" "25000.00" "0.5")))

(test "new-claim fills blank fields with the demo defaults"
  (let ([claim (new-claim "run-1" (with-fields (test-claim-request) "recipient_name" ""))])
    (assert-string= "run-1" (get claim "claim_id"))
    (assert-string= "25000.00" (get claim "amount"))
    (assert-string= default-originator-name (get claim "originator_name"))
    (assert-string= default-recipient-name (get claim "recipient_name"))))

(test "SQL steps bind their values"
  ;; A quote in the policy id must reach the database as data, never as SQL.
  (let ([claim (with-fields (test-claim) "policy_id" "P'1; DROP TABLE CLAIMS")])
    (let ([oracle (event-args (oracle-claim-event claim))])
      (assert (string:has-suffix? (get oracle "sql") "POLICY_ID = :1"))
      (assert-equal (vector "P'1; DROP TABLE CLAIMS") (get oracle "args")))
    (let ([mysql (event-args (policy-check-event claim))])
      (assert (not (string:contains? (get mysql "sql") "DROP")))
      (assert-equal (vector "P'1; DROP TABLE CLAIMS") (get mysql "args")))))

(test "the SAP payment binds all ten values"
  (let* ([payment (payment-record (sorted-map "payment_id" "PAY-9" "status" "approved"))]
         [args (get (event-args (sap-payment-event payment "25000.00" "5637144576")) "args")])
    (assert= 10 (length args))
    (assert-string= "PAY-9" (nth args 0))
    (assert-string= "25000.00" (nth args 4))
    (assert-string= "approved" (nth args 8))
    (assert-string= "5637144576" (nth args 9))))

(test "parse-oracle-claim reads the first row"
  (let ([record (parse-oracle-claim (get test-replies "oracle-claim"))])
    (assert-string= "CLM-4567" (get record "claim_id"))
    (assert-string= "Doe" (get (get record "claimant") "last_name")))
  (assert-string= "Oracle has no claim for this policy"
                  (bad-reply-message (lambda () (parse-oracle-claim (sorted-map "rows" (vector)))))))

(test "parse-screening reads each Equifax wrapper"
  (let ([inner (sorted-map "status" "Pass" "pstatus_det" "Clear" "hit_value_pep" 1)])
    (map ()
         (lambda (reply)
           (let ([s (parse-screening reply)])
             (assert-string= "Clear" (get s "pstatus_det"))
             (assert= 1 (get s "hit_pep"))
             (assert= 0 (get s "hit_emb"))))
         (list (sorted-map "equifax" (sorted-map "entity_screening_response" inner))
               (sorted-map "entity_screening_response" inner)
               (sorted-map "entity_screening_response_nested" inner)
               inner)))
  (assert-string= "Equifax returned no screening"
                  (bad-reply-message (lambda () (parse-screening (vector))))))

(test "screening-concern passes only a clear screening with no hits"
  (assert-nil (screening-concern (parse-screening (get test-replies "equifax-screening"))))
  (assert-string= "1 PEP and 0 embargo hits"
                  (screening-concern (sorted-map "pstatus_det" "Clear" "hit_pep" 1 "hit_emb" 0)))
  (assert-string= "screening status Review"
                  (screening-concern (sorted-map "pstatus_det" "Review" "hit_pep" 0 "hit_emb" 0)))
  (assert-string= "screening status missing" (screening-concern (sorted-map))))

(test "the Teams thread says why a screening needs review"
  (let ([flagged (event-args (teams-thread-event (test-claim)
                                                 (sorted-map "pstatus_det" "Review" "hit_pep" 0 "hit_emb" 0)))]
        [passed (event-args (teams-thread-event (test-claim)
                                                (sorted-map "pstatus_det" "Clear" "hit_pep" 0 "hit_emb" 0)))])
    (assert-string= "Equifax Screening Alert" (get flagged "title"))
    (assert-string= "Claim run-1 flagged for review: screening status Review" (get flagged "content"))
    (assert-string= "Equifax Screening Passed" (get passed "title"))))

(test "parse-active-policy needs a row"
  (assert-string= "Active" (get (parse-active-policy (get test-replies "policy-check")) "status"))
  (assert-string= "the policy is not active"
                  (bad-reply-message (lambda () (parse-active-policy (vector))))))

(test "parse-id-document needs text that names the claim"
  (let ([doc (get test-replies "id-document")])
    (assert-string= "id-verification.txt" (get (parse-id-document doc "CLM-4567") "file"))
    (assert-string= "the ID document does not name claim CLM-9999"
                    (bad-reply-message (lambda () (parse-id-document doc "CLM-9999"))))
    (assert-string= "the ID document is not text"
                    (bad-reply-message (lambda () (parse-id-document (with-fields doc "type" "pdf") "CLM-4567"))))
    ;; The id must stand alone: CLM-456 is part of CLM-4567, and 12 is part
    ;; of the date 2025-11-12.
    (map ()
         (lambda (id)
           (assert-string= (format-string "the ID document does not name claim {}" id)
                           (bad-reply-message (lambda () (parse-id-document doc id)))))
         (list "CLM-456" "LM-4567" "4567" "12" "2025" "a.b"))))

(test "readers of the remaining replies"
  (assert-string= "UnderReview" (get (parse-guidewire-claim (get test-replies "guidewire-claim")) "status"))
  (assert-string= "ApprovedForSettlement" (parse-guidewire-approval (get test-replies "guidewire-approval")))
  (let ([contract (parse-esignature-contract (get test-replies "esignature-contract"))])
    (assert-string= "contract-abc123" (get contract "contract_id"))
    (assert-string= "https://esign.example.com/sign/abc123" (get contract "sign_url")))
  (assert-string= "a0X5g000000XYZ1" (parse-salesforce-record-id (get test-replies "salesforce-invoice")))
  (assert-string= "sent" (parse-sent (get test-replies "invoice-email")))
  (assert-string= "INV-10001" (get (parse-zoho-invoice (get test-replies "zoho-invoice")) "invoice_id"))
  (assert-string= "text" (get (parse-document (get test-replies "settlement-document")) "type"))
  (assert-string= "INC0010001" (get (parse-servicenow-incident (get test-replies "servicenow-incident")) "number"))
  (assert-string= "INC7" (get (parse-servicenow-incident (sorted-map "incident_number" "INC7" "incident_id" "x")) "number"))
  (assert-string= "SAP-TXN-1001" (parse-sap-payment (get test-replies "sap-payment")))
  (assert-string= "1 row(s)" (parse-sap-payment (sorted-map "rows_affected" 1))))

(test "parse-d365fo-journal returns the record id as a string"
  (assert-string= "5637144576" (parse-d365fo-journal (get test-replies "d365fo-journal")))
  (assert-string= "42" (parse-d365fo-journal (sorted-map "data" (sorted-map "RecId" 42))))
  (assert-string= "T-1" (parse-d365fo-journal (sorted-map "transaction_id" "T-1")))
  (assert-string= "D365FO returned no journal record id"
                  (bad-reply-message (lambda () (parse-d365fo-journal (sorted-map "record" (sorted-map)))))))

(test "readers reject a reply with nothing to read"
  (map ()
       (lambda (reader)
         (assert (string? (bad-reply-message (lambda () (funcall reader (sorted-map "unexpected" true)))))))
       (list parse-teams-thread parse-guidewire-claim parse-guidewire-approval
             parse-esignature-contract parse-salesforce-record-id
             parse-zoho-invoice parse-document parse-servicenow-incident parse-sap-payment)))

(test "with-fields copies and does not change its input"
  (let* ([m (sorted-map "a" 1)]
         [m2 (with-fields m "a" 2 "b" 3)])
    (assert= 1 (get m "a"))
    (assert= 2 (get m2 "a"))
    (assert= 3 (get m2 "b"))))

(test "the Zoho invoice is for the claim amount in the claim currency"
  (let* ([json-data (get (event-args (zoho-invoice-event (test-claim))) "json_data")]
         [item (first (get json-data "line_items"))])
    (assert-string= claim-currency (get json-data "currency_code"))
    (assert= 25000.0 (get item "rate")))
  (assert-string= claim-currency
                  (get (payment-record (sorted-map "payment_id" "P" "status" "approved")) "currency")))

(test "the Guidewire approval uses the field names of its OpenAPI spec"
  (let ([args (event-args (guidewire-approval-event (test-claim)))])
    (assert-string= "GW-1001" (get args "claim_id"))
    (assert-string= "Handler" (get args "approved_by"))
    (assert-nil (get args "claimId"))))

(test "parse-guidewire-approval refuses a claim Guidewire did not approve"
  (assert-string= "Guidewire did not approve the claim: Rejected"
                  (bad-reply-message (lambda () (parse-guidewire-approval (sorted-map "approval" "Rejected")))))
  (assert-string= "Guidewire did not confirm the approval"
                  (bad-reply-message (lambda () (parse-guidewire-approval (sorted-map "status" "ok"))))))

(test "parse-sent refuses a message that did not go"
  (assert-string= "the message was not sent: SMTP auth refused"
                  (bad-reply-message (lambda () (parse-sent (sorted-map "status" "failed" "error" "SMTP auth refused")))))
  (assert-string= "the message was not sent: status Failed"
                  (bad-reply-message (lambda () (parse-sent (sorted-map "status" "Failed")))))
  (assert-string= "updated" (parse-sent (sorted-map "status" "updated"))))

(test "parse-sent takes the email connector's empty reply as sent"
  (assert-string= "sent" (parse-sent (sorted-map))))

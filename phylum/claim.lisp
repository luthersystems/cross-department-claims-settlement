;; Copyright © 2025 Luther Systems, Ltd. All right reserved.
;; ----------------------------------------------------------------------------
;; The claim settlement process, from the first database lookup to the
;; payment record, as one defflow.
;;
;; Each await is one step.  The run waits at it, a later transaction (a
;; connector reply or a call to an input endpoint) resumes it, and the locals
;; are kept in between.  So the process reads top to bottom here, and
;; defflow keeps the state, refuses an input the run is not waiting for, and
;; stamps each connector request with an idempotency key.
;;
;; The run id is the claim id.  Generated endpoints:
;;   claim_start request_key req      start a claim (req: see claim-steps.lisp)
;;   claim_get run_id                 state, label, gen, result, vars.claim
;;   claim_contract_signed run_id input gen [request_key]
;;   claim_payment_approved run_id input gen [request_key]
;;   claim_payment_status run_id input gen [request_key]
;; An input needs the run's current gen, which a webhook sender does not
;; know, so the portal reads claim_get first and then calls the input (see
;; portal/oracle/endpoints.go).
;; ----------------------------------------------------------------------------
(in-package 'cdcs)
(use-package 'defflow)

;; Call reader on reply and its args.  Return {"value" V}, or {"problem" P}
;; when the reader raises: a reply the next step cannot use.
(defun read-reply (value reader &rest args)
  (handler-bind ([condition
                  (lambda (c &rest data)
                    (sorted-map "problem"
                                (if (equal? c 'bad-reply)
                                  (first data)
                                  (format-string "unreadable reply ({}): {}" c data))))])
    (sorted-map "value" (apply reader value args))))

;; (reply LABEL EVENT READER ARGS...) sends EVENT, waits for the reply and
;; returns (READER reply ARGS...).  A reply the reader rejects fails the run
;; with the reader's reason.  Without this, the error would fail the reply's
;; transaction, the hub does not resend a reply, and the run would wait out
;; its connector timeout before it failed with a bare "timeout".
(defmacro reply (label event reader &rest args)
  ;; The label also names the binding.  defflow tracks a local by its symbol
  ;; object, so each expansion needs a symbol from its own call site; one
  ;; symbol written here would be shared by every expansion.  So the label
  ;; is written bare, (reply oracle-claim ...), and quoted here.
  ;; The await and the fail run where the macro expands, in the flow body,
  ;; which the label-scope lint cannot see from here.
  (quasiquote
    (let ([(unquote label) (read-reply (await-connector (quote (unquote label)) (unquote event)) ; nolint:flow-label-scope
                                       (unquote reader) (unquote-splicing args))])
      (when (get (unquote label) "problem") (fail (get (unquote label) "problem"))) ; nolint:flow-label-scope
      (get (unquote label) "value"))))

;; ABS reports a payment as approved, rejected or pending, in any case.
(defun payment-decision (status-input)
  (string:lowercase (to-string (get status-input "status"))))

(defflow claim (ctx req)
  (:connector-msp "Org1MSP" :start-from ("Org1MSP") :admin-from ("Org1MSP")
   :connector-timeout "1h" :expose ("claim"))
  (let ([problem (claim-request-problem req)])
    (when problem (fail problem)))
  (let* ([claim (new-claim (flow:run-id ctx) req)]

         ;; WF1: find the claim in Oracle, screen the claimant with Equifax,
         ;; open a Teams thread with the result.
         [record (reply oracle-claim (oracle-claim-event claim) parse-oracle-claim)]
         [screening (reply equifax-screening (equifax-event claim (get record "claimant"))
                           parse-screening)]
         [thread (reply teams-thread (teams-thread-event claim screening) parse-teams-thread)]

         ;; WF2: check the claim in Guidewire and the policy in MySQL, check
         ;; the ID document in SharePoint, approve the claim in Guidewire.
         [guidewire (reply guidewire-claim (guidewire-claim-event claim) parse-guidewire-claim)]
         [policy (reply policy-check (policy-check-event claim) parse-active-policy)]
         [id-check (reply id-document (id-document-event) parse-id-document (get record "claim_id"))]
         [approval (reply guidewire-approval (guidewire-approval-event claim) parse-guidewire-approval)]

         ;; WF3: send the invoice for signature, record it in Salesforce,
         ;; tell finance.
         [contract (reply esignature-contract (esignature-event claim) parse-esignature-contract)]
         [sf-record-id (reply salesforce-invoice (salesforce-invoice-event claim contract)
                              parse-salesforce-record-id)])
    (reply invoice-email (invoice-email-event claim sf-record-id) parse-sent)

    ;; WF4: wait for the signed contract, then invoice in Zoho, fetch the
    ;; settlement document and open a ServiceNow incident for review.
    (let* ([signed (await-input 'contract-signed :from ("Org1MSP"))]
           [invoice (reply zoho-invoice (zoho-invoice-event claim) parse-zoho-invoice)]
           [document (reply settlement-document (settlement-document-event) parse-document)]
           [incident (reply servicenow-incident (servicenow-incident-event claim) parse-servicenow-incident)])

      ;; Payment: ask the payment team in the Teams thread, wait for their
      ;; sign-off, then for ABS to decide.  ABS may report "pending" first,
      ;; so wait again until it approves or rejects.
      (reply payment-notice (payment-notice-event claim thread invoice) parse-sent)
      (let ([approved-by (get (await-input 'payment-approved :from ("Org1MSP")) "signed_by")]
            [status ()])
        (while (or (nil? status) (equal? (payment-decision status) "pending"))
          (set! status (await-input 'payment-status :from ("Org1MSP"))))
        (let ([summary (sorted-map
                         "claim_id"            (get claim "claim_id")
                         "oracle_claim_id"     (get record "claim_id")
                         "screening"           (or (screening-concern screening) "passed")
                         "teams_thread_id"     (get thread "thread_id")
                         "guidewire_status"    (get guidewire "status")
                         "policy_status"       (get policy "status")
                         "id_document"         (get id-check "file")
                         "approval"            approval
                         "esign_contract_id"   (get contract "contract_id")
                         "sf_record_id"        sf-record-id
                         "contract_signed_by"  (get signed "signed_by")
                         "zoho_invoice_id"     (get invoice "invoice_id")
                       "settlement_document" document
                         "servicenow_incident" (get incident "number")
                         "payment_approved_by" approved-by
                         "payment_id"          (get status "payment_id"))])
          (unless (equal? (payment-decision status) "approved")
            (done (with-fields summary "decision" "payment rejected")))

          ;; WF5: post the payment journal in D365FO, then record the
          ;; payment and the journal's id in SAP HANA.
          (let* ([payment (payment-record status)]
                 [d365fo-txn-id (reply d365fo-journal (d365fo-journal-event payment) parse-d365fo-journal)]
                 [sap-txn (reply sap-payment (sap-payment-event payment (get claim "amount") d365fo-txn-id)
                                 parse-sap-payment)])
            (with-fields summary
                   "decision"       "paid"
                   "d365fo_txn_id"  d365fo-txn-id
                   "sap_txn"        sap-txn)))))))

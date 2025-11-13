(in-package 'sandbox)

;; Build input parameters for the unified claim process from a request map
;; This endpoint invokes the entire process (WF1 → WF2 → WF3 → WF4 → WF5)
(defun build-process-inputs (req)
  (let* ([policy-id (or (get req "policy_id")
                        (set-exception-business "missing policy_id"))])
    (sorted-map
      "policy_id"          policy-id
      "guidewire_claim_id" (get req "guidewire_claim_id")
      "gw_claim_id"        (get req "gw_claim_id")
      "signer_email"       (get req "signer_email")
      "signer_name"        (get req "signer_name")
      "invoice_amount"     (get req "invoice_amount")
      "originator_name"    (get req "originator_name")
      "recipient_name"     (get req "recipient_name")
      "issue_date"         (get req "issue_date"))))

(defendpoint "invoke_process" (req)
  (cc:infof (sorted-map "req" req) "invoke_process called")
  (let* ([inputs (build-process-inputs req)]
         [result (invoke-workflow claim-manager inputs)])
    (cc:infof (sorted-map "result" result) "invoke_process completed")
    (route-success (sorted-map "claim_id" (get result "claim_id")
                               "state" (get result "state")))))


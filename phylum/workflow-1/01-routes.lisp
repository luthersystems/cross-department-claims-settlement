(in-package 'cdcs)

;; Build input parameters for WF1 from a request map
;; Allows routes or other orchestrators to kick off WF1 consistently.
(defun build-wf1-inputs (req)
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

(defendpoint "upload_claim_wf1" (req)
  (let* ([inputs (build-wf1-inputs req)]
         [result (invoke-workflow claim-manager-wf1 inputs)])
    (route-success (sorted-map "claim_id" (get result "claim_id")))))

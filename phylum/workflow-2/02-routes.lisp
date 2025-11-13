(in-package 'cdcs)

;; Build input parameters for WF2 from a request map
;; This can be called from routes or from other workflows
(defun build-wf2-inputs (req)
  (let* ([policy-id (or (get req "policy_id")
                        (set-exception-business "missing policy_id"))]
         [guidewire-claim-id (or (get req "guidewire_claim_id")
                                 (get req "gw_claim_id")
                                 (set-exception-business "missing guidewire_claim_id"))])
    (sorted-map
      "policy_id" policy-id
      "gw_claim_id" guidewire-claim-id
      "signer_email" (get req "signer_email")
      "invoice_amount" (get req "invoice_amount")
      "signer_name" (get req "signer_name")
      "originator_name" (get req "originator_name")
      "recipient_name" (get req "recipient_name")
      "issue_date" (get req "issue_date"))))

(defendpoint "upload_claim_wf2" (req)
  (let* ([inputs (build-wf2-inputs req)]
         [result (invoke-workflow claim-manager-wf2 inputs)])
    (route-success (sorted-map "claim_id" (get result "claim_id")))))


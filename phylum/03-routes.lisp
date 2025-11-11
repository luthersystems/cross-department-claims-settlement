(in-package 'sandbox)
(use-package 'connector)

;; Build input parameters for WF3 from a request map
;; This can be called from routes or from other workflows (e.g., during chaining)
(defun build-wf3-inputs (req)
  (let* ([claim-id        (or (get req "claim_id")        (set-exception-business "missing claim_id"))]
         [invoice-amount  (or (get req "invoice_amount")  (set-exception-business "missing invoice_amount"))]
         [signer-name     (or (get req "signer_name")     (set-exception-business "missing signer_name"))]
         [signer-email    (or (get req "signer_email")    (set-exception-business "missing signer_email"))]
         [originator-name (or (get req "originator_name") "Acme Insurance Ltd.")]
         [recipient-name  (or (get req "recipient_name")  "BlueRiver Underwriting Partners")]
         [issue-date      (or (get req "issue_date")      (format-date (now) "%Y-%m-%d"))]
         [chain-to-wf4    (normalize-bool (get req "chain_to_wf4") *wf3-chain-enabled*)])
    (sorted-map
      "claim_id"        claim-id
      "invoice_amount"  invoice-amount
      "signer_name"     signer-name
      "signer_email"    signer-email
      "originator_name" originator-name
      "recipient_name"  recipient-name
      "issue_date"      issue-date
      "chain_to_wf4"    chain-to-wf4)))

(defendpoint "upload_claim_wf3" (req)
  (let* ([inputs (build-wf3-inputs req)]
         [result (invoke-workflow claim-manager-wf3 inputs)])
    (route-success (sorted-map "claim_id" (get result "claim_id")))))

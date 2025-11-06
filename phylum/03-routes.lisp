(in-package 'sandbox)
(use-package 'connector)

;; Proto shape you asked for (extend to include invoice params):
;; message StartInvoiceFlowRequest {
;;   string claim_id         = 1;
;;   string invoice_amount   = 2;  // or double
;;   string signer_name      = 3;
;;   string signer_email     = 4;
;;   string originator_name  = 5;  // optional
;;   string recipient_name   = 6;  // optional
;;   string issue_date       = 7;  // YYYY-MM-DD
;; }

(defendpoint "upload_claim_wf3" (req)
  (cc:infof (sorted-map "req" req) "upload_claim_wf3")
    (cc:infof (sorted-map "claim ID" (get req "claim_id")) "claim ID")
    (cc:infof (sorted-map "invoice_amount" (get req "invoice_amount")) "invoice_amount")
    (cc:infof (sorted-map "signer_name" (get req "signer_name")) "signer_name")


  (let* ([claim-id        (or (get req "claim_id")        (set-exception-business "missing claim_id"))]
         [invoice-amount  (or (get req "invoice_amount")  (set-exception-business "missing invoice_amount"))]
         [signer-name     (or (get req "signer_name")     (set-exception-business "missing signer_name"))]
         [signer-email    (or (get req "signer_email")    (set-exception-business "missing signer_email"))]
         [originator-name (or (get req "originator_name") "Acme Insurance Ltd.")]
         [recipient-name  (or (get req "recipient_name")  "BlueRiver Underwriting Partners")]
         [issue-date      (or (get req "issue_date")      "2025-11-05")]

         ;; create entity
         [claim     (new-connector-object claim-manager)]
         [claim-id  (get claim "claim_id")]

         ;; feed init state's parser with CH-style map
         [chresp  (sorted-map
                    "claim_id"        claim-id
                    "invoice_amount"  invoice-amount
                    "signer_name"     signer-name
                    "signer_email"    signer-email
                    "originator_name" originator-name
                    "recipient_name"  recipient-name
                    "issue_date"      issue-date)])
    (trigger-connector-object claim-manager claim-id chresp)
    (route-success
      (sorted-map
        "claim_id" claim-id
        "state"    "CLAIM_STATE_INVOICE_STATE_ESIG_CREATED"))))

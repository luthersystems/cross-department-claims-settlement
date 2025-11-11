(in-package 'sandbox)

(use-package 'connector)
(in-package 'sandbox)

(defendpoint "upload_claim_wf2" (req)
  (let* ([policy-id (or (get req "policy_id")
                        (set-exception-business "missing policy_id"))]
         [guidewire-claim-id (or (get req "guidewire_claim_id")
                        (set-exception-business "missing claim_id"))]

         ;; Step 1: create new object -> commits a tx (no events)
         [claim     (new-connector-object claim-manager-wf2)]
         [claim-id  (get claim "claim_id")]

         ;; Step 2: The init state's parse expects a CH response style input
         ;; Also pass through optional fields for workflow 3 chaining:
         ;; signer_email, invoice_amount, signer_name, originator_name, recipient_name, issue_date
         [chresp    (sorted-map
                      "policy_id" policy-id
                      "gw_claim_id" guidewire-claim-id
                      "signer_email" (get req "signer_email")
                      "invoice_amount" (get req "invoice_amount")
                      "signer_name" (get req "signer_name")
                      "originator_name" (get req "originator_name")
                      "recipient_name" (get req "recipient_name")
                      "issue_date" (get req "issue_date"))])

    ;; Step 3: trigger flow
    (trigger-connector-object claim-manager-wf2 claim-id chresp)

    (route-success
      (sorted-map
        "claim_id" claim-id
        "state"    "CLAIM_STATE_ORACLE_RETRIEVED"))))


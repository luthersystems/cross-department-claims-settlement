(in-package 'sandbox)

(use-package 'connector)
(in-package 'sandbox)

(defendpoint "upload_claim_wf2" (req)
  (let* ([policy-id (or (get req "policy_id")
                        (set-exception-business "missing policy_id"))]
         [guidewire-claim-id (or (get req "guidewire_claim_id")
                        (set-exception-business "missing claim_id"))]

         ;; Step 1: create new object -> commits a tx (no events)
         [claim     (new-connector-object claim-manager)]
         [claim-id  (get claim "claim_id")]

         ;; Step 2: The init state's parse expects a CH response style input
         [chresp    (sorted-map "policy_id" policy-id "gw_claim_id" guidewire-claim-id)])

    ;; Step 3: trigger flow
    (trigger-connector-object claim-manager claim-id chresp)

    (route-success
      (sorted-map
        "claim_id" claim-id
        "state"    "CLAIM_STATE_ORACLE_RETRIEVED"))))


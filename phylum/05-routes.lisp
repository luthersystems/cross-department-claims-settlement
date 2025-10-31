(in-package 'sandbox)

(use-package 'connector)

(defendpoint "upload_claim_wf5" (req)
  (let* ([claim-id   (or (get req "claim_id")
                         (set-exception-business "missing claim_id"))]
         [policy-id  (or (get req "policy_id")
                         (set-exception-business "missing policy_id"))]

         ;; Initialize durable claim object
         [claim      (new-connector-object claim-manager)]
         [claim      (assoc! claim
                        "claim_id"  claim-id
                        "policy_id" policy-id
                        "state"     "CLAIM_STATE_NEW")]

         ;; Emulate ConnectorHub-style payload (even if empty)
         [chresp     (sorted-map
                       "claim_id"  claim-id
                       "policy_id" policy-id)]

         ;; Run one state step (parse → stage-ephemeral → stage-durable → transition)
         [step       (run-state-step "claim" "claim_id" claim chresp)]
         [clm1       (get step "put")]
         [events     (get step "events")])

    ;; Persist durable doc and trigger connector events
    (claim-manager 'put clm1)
    (trigger-connector-object claim-manager claim-id
      (sorted-map "put" clm1 "events" events))

    (route-success
      (sorted-map
        "claim_id" claim-id
        "state"    (get clm1 "state")))))

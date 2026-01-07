(in-package 'cdcs)

;; Helper function to merge multiple state specs
(defun merge-state-specs (&rest specs)
  (let* ([merged (sorted-map)])
    (map () (lambda (spec)
              (map () (lambda (key)
                        (assoc! merged key (get spec key)))
                   (keys spec)))
         specs)
    merged))

;; Custom State Handlers for Unified Process

(defun waiting-for-payment-signature-state-handler ()
  (labels
    ([receive (resp entity accessors)
      (let* ([claim-id    (or (get resp "claim_id") (get entity "claim_id"))]
             [signed-by   (get resp "signedBy")]
             [policy-id   (get entity "policy_id")]
             [amount      (get entity "amount")]
             [invoice-id  (get entity "zoho_invoice_id")]
             [thread-id   (get entity "teams_thread_id")]
             [message-id  (get entity "teams_message_id")])
        (sorted-map
          "claim_id"    claim-id
          "signed_by"   signed-by
          "thread_id"   thread-id
          "message_id"  message-id
          "message"     (format-string
                          "📋 **Claim Payment Request**\n\n"
                          "**Claim ID:** {}\n"
                          "**Policy ID:** {}\n"
                          "**Amount:** {}\n"
                          "**Invoice ID:** {}\n"
                          "**Status:** Claim approved, invoice generated, contract signed\n"
                          "⏳ **Awaiting payment approval**\n\n"
                          "✅ Please review and approve payment for this claim."
                          (or claim-id "N/A")
                          (or policy-id "N/A")
                          (or amount "N/A")
                          (or invoice-id "N/A"))))]

     [validate (received entity accessors)
       (when (nil? (get received "claim_id")) (set-exception-business "missing claim_id"))
       received]

     [decide-next-state (validated entity accessors)
       "CLAIM_STATE_PAYMENT_TEAM_NOTIFIED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (let* ([has-signature (get validated "signed_by")]
             [result (if has-signature
                       (sorted-map "payment_signed_by" (get validated "signed_by"))
                       (sorted-map))])
        result)]

     [send (entity validated accessors)
      (let* ([thread-id  (get validated "thread_id")]
             [message-id (get validated "message_id")]
             [message    (get validated "message")])
        (if (and thread-id message-id)
          (vector (mk-teams-update-thread-event entity thread-id message-id message accessors))
          (vector)))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

(defun payment-team-notified-state-handler ()
  (labels
    ([receive (resp entity accessors) (sorted-map)]
     [validate (received entity accessors) received]
     [decide-next-state (validated entity accessors) "CLAIM_STATE_PAYMENT_TEAM_NOTIFIED"]
     [store-ephemeral (entity validated accessors) (vector)]
     [store-durable (entity validated accessors) (vector)]
     [send (entity validated accessors) (vector)])
    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))
      
;; Combined state spec
(set 'state-spec-claim
     (merge-state-specs
       state-spec-wf1
       state-spec-wf2
       state-spec-wf3
       state-spec-wf4
       (sorted-map
         "CLAIM_STATE_WAITING_FOR_PAYMENT_SIGNATURE" (waiting-for-payment-signature-state-handler)
         "CLAIM_STATE_PAYMENT_TEAM_NOTIFIED"         (payment-team-notified-state-handler))
  
       (sorted-map
         "WF1_CLAIM_TEAMS_THREAD_CREATED"           (wf1-teams-thread-created-state-handler 
                                                      "WF2_CLAIM_STATE_INIT" 
                                                      (lambda (entity) 
                                                        (trigger-connector-object claim-manager (get entity "claim_id") (sorted-map))))

         "WF2_CLAIM_STATE_GUIDEWIRE_APPROVED"      (wf2-claim-guidewire-approved-state-handler
                                                      "WF3_CLAIM_STATE_INVOICE_INIT"
                                                      (lambda (entity)
                                                        (trigger-connector-object claim-manager (get entity "claim_id") (sorted-map))))

         "WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED" (wf3-invoice-email-dispatched-state-handler 
                                                       "WF4_CLAIM_STATE_INIT"
                                                       (lambda (entity)
                                                         (trigger-connector-object claim-manager (get entity "claim_id") (sorted-map))))
         
         "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED" (wf4-servicenow-incident-created-state-handler 
                                                         "CLAIM_STATE_WAITING_FOR_PAYMENT_SIGNATURE"
                                                         (lambda (entity) ())))))

(set 'claim-manager
     (singleton (mk-entity-manager
                 "claim"
                 "claim_id"
                 "WF1_CLAIM_STATE_NEW"
                 state-spec-claim)))

(register-connector-factory claim-manager)
(register-workflow "process" claim-manager)

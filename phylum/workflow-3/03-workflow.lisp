;; 1) INIT → ESIG_CREATED
(defun wf3-invoice-init-state-handler ()
  (labels
    ([parse (resp entity)
      ;; Prioritize resp (explicit request) over entity (accumulated data), then defaults
      ;; For unified process, resp is empty so falls back to entity
      (let* ([teams-thread-id (get entity "teams_thread_id")]
             [teams-message-id (get entity "teams_message_id")]
             [claim-id (get entity "claim_id")]
            ;  [claim-id        (or (get resp "claim_id") (get entity "claim_id") (set-exception-business "missing claim_id"))]
             [amount          (or (get resp "invoice_amount") (get entity "invoice_amount") (set-exception-business "missing invoice_amount"))]
             [signer-name     (or (get resp "signer_name") (get entity "signer_name") (set-exception-business "missing signer_name"))]
             [signer-email    (or (get resp "signer_email") (get entity "signer_email") (set-exception-business "missing signer_email"))]
             [originator-name (or (get resp "originator_name") (get entity "originator_name") *wf3-default-originator-name*)]
             [recipient-name  (or (get resp "recipient_name") (get entity "recipient_name") *wf3-default-recipient-name*)]
             [issue-date      (or (get resp "issue_date") (get entity "issue_date") *wf3-default-issue-date*)]
             [policy-id       (or (get resp "policy_id") (get entity "policy_id"))])
        (cc:infof (sorted-map
                    "claim_id" claim-id
                    "teams_thread_id" teams-thread-id
                    "teams_message_id" teams-message-id
                    "entity_keys" (keys entity)
                    "has_claim_id_in_entity" (not (nil? claim-id)))
                  "WF3 INIT parse: checking claim_id and Teams IDs")
        (sorted-map
          "amount"          amount
          "signer_name"     signer-name
          "signer_email"    signer-email
          "originator_name" originator-name
          "recipient_name"  recipient-name
          "issue_date"      issue-date
          "policy_id"       policy-id))]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      ;; Preserve Teams IDs from entity - don't lose them when storing parsed data
      ;; NEVER include claim_id in stage-durable - it causes full entity replacement
      (let* ([teams-thread-id (get entity "teams_thread_id")]
             [teams-message-id (get entity "teams_message_id")]
             [result parsed])
        ;; Preserve Teams IDs if they exist (but NOT claim_id)
        (when teams-thread-id
          (assoc! result "teams_thread_id" teams-thread-id))
        (when teams-message-id
          (assoc! result "teams_message_id" teams-message-id))
        result)]
     [create-events (entity parsed accessors)
      ;; Use entity (which has claim_id) instead of parsed (which doesn't)
      ;; The event creator will read fields from entity
      (vector (mk-esignature-create-contract-event entity))])
    (mk-state-handler
      :next "WF3_CLAIM_STATE_INVOICE_ESIG_CREATED"
      :parse parse :stage-ephemeral stage-ephemeral
      :stage-durable stage-durable :create-events create-events)))

;; 2) ESIG_CREATED → SF_SYNCED
(defun wf3-invoice-esig-created-state-handler ()
  (labels
    ([parse (resp entity)
      (let* ([teams-thread-id (get entity "teams_thread_id")]
             [teams-message-id (get entity "teams_message_id")]
             [claim-id (get entity "claim_id")]
             [parsed (parse-esignature-create-contract resp)])
        parsed)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (let* ([claim-id-before (get entity "claim_id")]
             [result (sorted-map
                       "esign_contract_id"    (get parsed "contract_id")
                       "esign_sign_page_url"  (get parsed "sign_page_url")
                       "esign_status"         (get parsed "contract_status"))])
        (cc:infof (sorted-map
                    "claim_id_before" claim-id-before
                    "claim_id_in_result" (get result "claim_id")
                    "staged_durable_keys" (keys result)
                    "entity_keys" (keys entity))
                  "WF3 ESIG_CREATED stage-durable: checking claim_id preservation")
        result)]
     [create-events (entity parsed accessors)
      (let* ([claim-id-in-entity (get entity "claim_id")]
             [event (mk-salesforce-create-invoice-event
                      entity
                      (sorted-map
                        "contract_id"   (get parsed "contract_id")
                        "sign_page_url" (get parsed "sign_page_url")))])
        (cc:infof (sorted-map
                    "claim_id_in_entity" claim-id-in-entity
                    "entity_keys" (keys entity))
                  "WF3 ESIG_CREATED create-events: checking claim_id before event creation")
        (vector event))])
    (mk-state-handler
      :next "WF3_CLAIM_STATE_INVOICE_SF_SYNCED"
      :parse parse :stage-ephemeral stage-ephemeral
      :stage-durable stage-durable :create-events create-events)))

;; 3) SF_SYNCED → EMAIL_DISPATCHED
(defun wf3-invoice-sf-synced-state-handler ()
  (labels
    ([parse (resp entity) (parse-salesforce-create-record resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (let* ([claim-id-before (get entity "claim_id")]
             [result (sorted-map "sf_record_id" (get parsed "sf_record_id"))])
        (cc:infof (sorted-map
                    "claim_id_before" claim-id-before
                    "claim_id_in_result" (get result "claim_id")
                    "staged_durable_keys" (keys result)
                    "entity_keys" (keys entity))
                  "WF3 SF_SYNCED stage-durable: checking claim_id preservation")
        result)]
     [create-events (entity parsed accessors)
      (let* ([claim-id-in-entity (get entity "claim_id")]
             [event (mk-smtp-send-email-event
                      entity
                      (sorted-map "sf_record_id" (get parsed "sf_record_id")))])
        (cc:infof (sorted-map
                    "claim_id_in_entity" claim-id-in-entity
                    "entity_keys" (keys entity))
                  "WF3 SF_SYNCED create-events: checking claim_id before event creation")
        (vector event))])
    (mk-state-handler
      :next "WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED"
      :parse parse :stage-ephemeral stage-ephemeral
      :stage-durable stage-durable :create-events create-events)))

;; 4) EMAIL_DISPATCHED → DONE (or WF4_INIT if chained)
(defun wf3-invoice-email-dispatched-state-handler (&optional next-state after-storage-hook)
  (labels
    ([parse (resp entity)
       (parse-smtp-send resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
       (let* ([claim-id-before (get entity "claim_id")]
              [result (sorted-map "email_dispatched" true)])
         (cc:infof (sorted-map
                     "claim_id_before" claim-id-before
                     "claim_id_in_result" (get result "claim_id")
                     "staged_durable_keys" (keys result)
                     "entity_keys" (keys entity))
                   "WF3 EMAIL_DISPATCHED stage-durable: checking claim_id preservation")
         result)]
     [create-events (entity parsed accessors)
       (cc:infof (sorted-map
                   "claim_id_in_entity" (get entity "claim_id")
                   "entity_keys" (keys entity))
                 "WF3 EMAIL_DISPATCHED create-events: checking claim_id")
       ()])
    (mk-state-handler
      :next (or next-state "WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED")
      :parse parse :stage-ephemeral stage-ephemeral
      :stage-durable stage-durable 
      :create-events create-events
      :after-storage-hook after-storage-hook)))


;; build-event moved to substr_generic_parser.lisp

(defun mk-email-body (signer-name claim-id sf-url)
  (string:join
    (list
      (format-string "Hi {}," signer-name)
      ""
      (format-string
        "The inter-entity settlement invoice for claim {} has been generated "
        claim-id)
      "and sent for signature via eSignature."
      ""
      (format-string "View in Salesforce: {}" sf-url)
      ""
      "— ConnectorHub Automation")
    "\n"))

;; SMTP: send notification email
(defun mk-smtp-send-email-event (entity args)
  (let* (
         [sf-id   (get args "sf_record_id")]
         [sf-url  (if sf-id
                      (format-string "{}/{}" *wf3-default-sf-base-url* sf-id)
                      "")]
         [claim-id    (get entity "claim_id")]
         [signer-name (get entity "signer_name")]
         [signer-email (get entity "signer_email")]

         ;; Build subject with variable substitution
         [subject (format-string "Settlement Invoice {} Sent for Signature" claim-id)]

         ;; Build body using string:join for clarity
         [body (string:join
                 (list
                   (format-string "Hi {}," "Jack")
                   ""
                   (format-string
                     "The inter-entity settlement invoice for claim {} has been generated "
                     claim-id)
                   "and sent for signature via eSignature."
                   ""
                   (format-string "View in Salesforce: {}" sf-url)
                   ""
                   "— ConnectorHub Automation")
                 "\n")]

         ;; Construct connector request
         [req (mk-email-req *wf3-default-email-to* subject body)])
    (build-event entity req "dispatch invoice email" "EMAIL")))

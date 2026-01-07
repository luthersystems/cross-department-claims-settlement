;; 1) INIT → ESIG_CREATED
(defun wf3-invoice-init-state-handler ()
  (labels
    ([receive (resp entity accessors)
      (let* ([amount          (or (get resp "invoice_amount") (get entity "invoice_amount") (set-exception-business "missing invoice_amount"))]
             [signer-name     (or (get resp "signer_name") (get entity "signer_name") (set-exception-business "missing signer_name"))]
             [signer-email    (or (get resp "signer_email") (get entity "signer_email") (set-exception-business "missing signer_email"))]
             [originator-name (or (get resp "originator_name") (get entity "originator_name") *wf3-default-originator-name*)]
             [recipient-name  (or (get resp "recipient_name") (get entity "recipient_name") *wf3-default-recipient-name*)]
             [issue-date      (or (get resp "issue_date") (get entity "issue_date") *wf3-default-issue-date*)]
             [policy-id       (or (get resp "policy_id") (get entity "policy_id"))])
        (sorted-map
          "amount"          amount
          "signer_name"     signer-name
          "signer_email"    signer-email
          "originator_name" originator-name
          "recipient_name"  recipient-name
          "issue_date"      issue-date
          "policy_id"       policy-id))]

     [validate (received entity accessors)
       (when (nil? (get received "amount")) (set-exception-business "missing amount"))
       received]

     [decide-next-state (validated entity accessors)
       "WF3_CLAIM_STATE_INVOICE_ESIG_CREATED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (let* ([teams-thread-id (get entity "teams_thread_id")]
             [teams-message-id (get entity "teams_message_id")]
             [result validated])
        (when teams-thread-id
          (assoc! result "teams_thread_id" teams-thread-id))
        (when teams-message-id
          (assoc! result "teams_message_id" teams-message-id))
        result)]

     [send (entity validated accessors)
      (vector (mk-esignature-create-contract-event entity accessors))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

;; 2) ESIG_CREATED → SF_SYNCED
(defun wf3-invoice-esig-created-state-handler ()
  (labels
    ([receive (resp entity accessors)
       (parse-esignature-create-contract resp)]

     [validate (received entity accessors)
       (when (nil? (get received "contract_id")) (set-exception-business "missing contract_id"))
       received]

     [decide-next-state (validated entity accessors)
       "WF3_CLAIM_STATE_INVOICE_SF_SYNCED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
       (sorted-map
         "esign_contract_id"    (get validated "contract_id")
         "esign_sign_page_url"  (get validated "sign_page_url")
         "esign_status"         (get validated "contract_status"))]

     [send (entity validated accessors)
       (let* ([event (mk-salesforce-create-invoice-event
                      entity
                      (sorted-map
                        "contract_id"   (get validated "contract_id")
                        "sign_page_url" (get validated "sign_page_url"))
                      accessors)])
        (vector event))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

;; 3) SF_SYNCED → EMAIL_DISPATCHED
(defun wf3-invoice-sf-synced-state-handler ()
  (labels
    ([receive (resp entity accessors)
       (parse-salesforce-create-record resp)]

     [validate (received entity accessors)
       (when (nil? (get received "sf_record_id")) (set-exception-business "missing sf_record_id"))
       received]

     [decide-next-state (validated entity accessors)
       "WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map "sf_record_id" (get validated "sf_record_id"))]

     [send (entity validated accessors)
      (vector (mk-smtp-send-email-event
                entity
                (sorted-map "sf_record_id" (get validated "sf_record_id"))
                accessors))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

;; 4) EMAIL_DISPATCHED → DONE
(defun wf3-invoice-email-dispatched-state-handler (&optional next-state after-storage-hook)
  (labels
    ([receive (resp entity accessors)
       (parse-smtp-send resp)]

     [validate (received entity accessors)
       received]

     [decide-next-state (validated entity accessors)
       (or next-state "WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED")]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
       (sorted-map "email_dispatched" true)]

     [send (entity validated accessors) (vector)])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send
      :after-storage-hook after-storage-hook)))

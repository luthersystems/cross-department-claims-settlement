;; 1) INIT → ESIG_CREATED
(defun wf3-invoice-init-state-handler ()
  (labels
    ([parse (resp entity)
      ;; pull everything from request entity
      (let* ([claim-id        (or (get resp "claim_id") (set-exception-business "missing claim_id"))]
             [amount          (or (get resp "invoice_amount") (set-exception-business "missing invoice_amount"))]
             [signer-name     (or (get resp "signer_name") (set-exception-business "missing signer_name"))]
             [signer-email    (or (get resp "signer_email") (set-exception-business "missing signer_email"))]
             [originator-name (or (get resp "originator_name") *wf3-default-originator-name*)]
             [recipient-name  (or (get resp "recipient_name") *wf3-default-recipient-name*)]
             [issue-date      (or (get resp "issue_date") *wf3-default-issue-date*)]
             [policy-id       (or (get resp "policy_id") (get entity "policy_id"))])
        (sorted-map
          "claim_id"        claim-id
          "amount"          amount
          "signer_name"     signer-name
          "signer_email"    signer-email
          "originator_name" originator-name
          "recipient_name"  recipient-name
          "issue_date"      issue-date
          "policy_id"       policy-id))]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors) parsed]
     [create-events (entity parsed accessors)
      (vector (mk-esignature-create-contract-event parsed))])
    (mk-state-handler
      :next "WF3_CLAIM_STATE_INVOICE_ESIG_CREATED"
      :parse parse :stage-ephemeral stage-ephemeral
      :stage-durable stage-durable :create-events create-events)))

;; 2) ESIG_CREATED → SF_SYNCED
(defun wf3-invoice-esig-created-state-handler ()
  (labels
    ([parse (resp entity) (parse-esignature-create-contract resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (cc:infof (sorted-map "parsed" parsed) "here is parsed esig resp") 
      (sorted-map
        "esign_contract_id"    (get parsed "contract_id")
        "esign_sign_page_url"  (get parsed "sign_page_url")
        "esign_status"         (get parsed "contract_status"))]
     [create-events (entity parsed accessors)
      (vector (mk-salesforce-create-invoice-event
                entity
                (sorted-map
                  "contract_id"   (get parsed "contract_id")
                  "sign_page_url" (get parsed "sign_page_url"))))])
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
      (sorted-map "sf_record_id" (get parsed "sf_record_id"))]
     [create-events (entity parsed accessors)
      (vector (mk-smtp-send-email-event
                entity
                (sorted-map "sf_record_id" (get parsed "sf_record_id"))))])
    (mk-state-handler
      :next "WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED"
      :parse parse :stage-ephemeral stage-ephemeral
      :stage-durable stage-durable :create-events create-events)))

;; 4) EMAIL_DISPATCHED → DONE
(defun wf3-invoice-email-dispatched-state-handler ()
  (labels
    ([parse (resp entity) (parse-smtp-send resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors) (sorted-map "email_dispatched" true)]
     [create-events (entity parsed accessors) ()])
    (mk-state-handler
      :next "WF3_CLAIM_STATE_DONE"
      :parse parse :stage-ephemeral stage-ephemeral
      :stage-durable stage-durable 
      :create-events create-events)))

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


(defun wf3-claim-done-state-handler ()
  (labels
    ([parse (resp entity) (parse-generic-resp resp)]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors) ()]
     [create-events (entity parsed accessors) ()])
    (mk-state-handler
      :next            "WF3_CLAIM_STATE_DONE"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

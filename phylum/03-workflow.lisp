;; ===== eSignature defaults (configurable later) =====
(set '*ESIG_TEMPLATE_ID*        "91550d63-d436-43bb-9068-a39b46a0e005")
(set '*ESIG_LOCALE*             "en-GB")
(set '*ESIG_TEST_MODE*          "yes")      ;; "yes"|"no"
(set '*ESIG_EXPIRES_IN_HOURS*   "336")      ;; 14 days
(set '*ESIG_LABELS*             (vector "inter-entity" "settlement"))
(set '*ESIG_CUSTOM_WEBHOOK_URL* "")

;; ===== Salesforce defaults =====
(set '*SF_OBJECT_API*           "Settlement_Invoice__c")
(set '*SF_FIELDS_MAP*           (sorted-map
  "name"           "Name__c"                ;; use "Name" if you kept standard Name
  "claim_id"       "Claim_ID__c"
  "contract_id"    "Contract_ID__c"
  "amount"         "Amount__c"
  "status"         "Status__c"
  "sign_url"       "esignature_sign_page_url__c"
  "invoice_amount" "invoice_amount__c"
  "signer_name"    "signer_name__c"))
(set '*SF_BASE_URL*             "https://orgfarm-cc0b69f3bb-dev-ed.develop.my.salesforce.com")

;; ===== Email defaults =====
(set '*EMAIL_SUBJECT_TEMPLATE*
     "Settlement Invoice {{claim_id}} Sent for Signature")
(set '*EMAIL_BODY_TEMPLATE*
     (concat 'string
       "Hi {{signer_name}},\n\n"
       "The inter-entity settlement invoice for claim {{claim_id}} has been generated and sent for signature via eSignature.\n\n"
       "View in Salesforce: {{sf_record_url}}\n\n"
       "— ConnectorHub Automation"))

(set '*EMAIL_FROM*              "ap@acme.example")

;; eSignature: create contract from template
(defun mk-esignature-create-contract-event (entity)
  (let* ([args (sorted-map
                 "template_id"      (or (get entity "template_id") *ESIG_TEMPLATE_ID*)
                 "title"            (or (get entity "title")
                                        (format-string "Inter-Entity Invoice for Claim {}" (get entity "claim_id")))
                 "contract_source"  "mcpserver"
                 "mcp_query"        "Generate inter-entity invoice for signature"
                 "locale"           *ESIG_LOCALE*
                 "expires_in_hours" *ESIG_EXPIRES_IN_HOURS*
                 "test"             *ESIG_TEST_MODE*
                 "labels"           *ESIG_LABELS*
                 "placeholder_fields" (vector
                   (sorted-map "api_key" "claim_id"        "value" (get entity "claim_id"))
                   (sorted-map "api_key" "originator_name" "value" (get entity "originator_name"))
                   (sorted-map "api_key" "recipient_name"  "value" (get entity "recipient_name"))
                   (sorted-map "api_key" "issue_date"      "value" (get entity "issue_date"))
                   (sorted-map "api_key" "amount"          "value" (get entity "amount")))
                 "signers" (vector
                   (sorted-map
                     "name"  (get entity "signer_name")
                     "email" (get entity "signer_email")
                     "signature_request_delivery_methods" (vector "email")
                     "signed_document_delivery_method"    "email"))
                 "emails" (sorted-map
                   "signature_request_subject" "Action Required: Review & Sign Inter-Entity Invoice"
                   "signature_request_text"    "Dear __FULL_NAME__,\n\nPlease review and sign the inter-entity settlement invoice."
                   "final_contract_subject"    "Invoice Signed Successfully"
                   "final_contract_text"       "Thank you, __FULL_NAME__, your contract has been signed and archived.")
                 )]
         [req (mk-connector-req
                (sorted-map
                  "kind" "KIND_ESIGNATURES"
                  "operation" "create_contract"
                  "args" args))])
    (build-event entity req "create invoice contract" "ESIGNATURE")))

;; Salesforce: create invoice record
(defun mk-salesforce-create-invoice-event (entity args)
  (cc:infof (sorted-map "entity" entity) "passed entity")

  (cc:infof (sorted-map "args" args) "passed args")
  (let* ([m *SF_FIELDS_MAP*]
         [data (sorted-map
                 (get m "name")           (format-string "Inter-Entity Invoice {}" (get entity "claim_id"))
                 (get m "claim_id")       (get entity "claim_id")
                 (get m "contract_id")    (get args "contract_id")
                 (get m "amount")         (get entity "amount")
                 (get m "status")         "AwaitingSignature"
                 (get m "sign_url")       (get args "sign_page_url")
                 (get m "invoice_amount") (get entity "amount")
                 (get m "signer_name")    (get entity "signer_name"))]
         [req (mk-connector-req
                (sorted-map
                  "kind" "KIND_SALESFORCE"
                  "operation" "create_record"
                  "args" (sorted-map
                           "object_name" "Settlement_Invoice__c"
                           "data"        (sorted-map
                              "Name__c"                         (format-string "Inter-Entity Invoice {}" (get entity "claim_id"))
                              "Claim_ID__c"                     (get entity "claim_id")
                              "Contract_ID__c"                  (get args "contract_id")
                              "Amount__c"                   (get entity "amount")
                              "Status__c"                        "AwaitingSignature"
                              "esignature_sign_page_url__c"      (get args "sign_page_url")
                              "invoice_amount__c"             (get entity "amount")
                              "signer_name__c"    (get entity "signer_name")))))])
    (build-event entity req "create sf invoice" "SALESFORCE")))

;; SMTP: send notification email
; (defun mk-smtp-send-email-event (entity args)
;   (let* ([sf-id        (get args "sf_record_id")]
;          [sf-url       (if sf-id (format-string "{}/{}" *SF_BASE_URL* sf-id) "")]
;          [subject      (string-replace *EMAIL_SUBJECT_TEMPLATE* "{{claim_id}}" (get entity "claim_id"))]
;          [body-temp    (-> *EMAIL_BODY_TEMPLATE*
;                            (string-replace "{{claim_id}}" (get entity "claim_id"))
;                            (string-replace "{{signer_name}}" (get entity "signer_name"))
;                            (string-replace "{{sf_record_url}}" sf-url))]
;          [req (mk-connector-req
;                 (sorted-map
;                   "kind" "KIND_SMTP"
;                   "operation" "send_email"
;                   "args" (sorted-map
;                            "to"      (get entity "signer_email")
;                            "subject" subject
;                            "body"    body-temp)))])
;     (build-event entity req "dispatch invoice email" "SMTP")))

;; eSignature: parse create_contract → {contract_id, sign_page_url, contract_status}
(defun parse-esignature-create-contract (resp)
  (let* ([decoded (parse-generic-resp resp)]
        [outer-data (get decoded "data")]
        [data (and outer-data (get outer-data "data"))]
        [contract (and data (get data "contract"))]
        [signers (and contract (get contract "signers"))]
        [first-s (and (vector? signers) (> (length signers) 0) (first signers))])

    (cc:infof (sorted-map "outer-data" outer-data) "parsed outer-data")
    (cc:infof (sorted-map "data" data) "parsed data data")
    (cc:infof (sorted-map "contract" contract) "parsed contract")
    ;; extract useful data for later workflow steps
    (sorted-map
      "contract_id"   (and contract (get contract "id"))
      "sign_page_url" (and first-s (get first-s "sign_page_url"))
      "contract_status" (and contract (get contract "status")))))

;; Salesforce: parse create_record → {sf_record_id}
(defun parse-salesforce-create-record (resp)
  (cc:infof (sorted-map "generic" (parse-generic-resp resp)) "generic salesforce resp parsed")
  (let* ([decoded (parse-generic-resp resp)]
         [id      (get decoded "id")])
    (if id
      (sorted-map "sf_record_id" id)
      (set-exception-business "Salesforce did not return an id"))))

;; SMTP: parse generic ok response
(defun parse-smtp-send (resp)
  (let* ([j (parse-generic-resp resp)])
    (or j (sorted-map "status" "OK"))))

;; 1) INIT → ESIG_CREATED
(defun wf3-invoice-init-state-handler ()
  (labels
    ([parse (resp entity)
      ;; pull everything from request entity
      (let* ([claim-id        (or (get resp "claim_id") (set-exception-business "missing claim_id"))]
             [amount          (or (get resp "invoice_amount") (set-exception-business "missing invoice_amount"))]
             [signer-name     (or (get resp "signer_name") (set-exception-business "missing signer_name"))]
             [signer-email    (or (get resp "signer_email") (set-exception-business "missing signer_email"))]
             [originator-name (or (get resp "originator_name") "Acme Insurance Ltd.")]
             [recipient-name  (or (get resp "recipient_name") "BlueRiver Underwriting Partners")]
             [issue-date      (or (get resp "issue_date") (format-date (now) "%Y-%m-%d"))])
        (sorted-map
          "claim_id"        claim-id
          "amount"          amount
          "signer_name"     signer-name
          "signer_email"    signer-email
          "originator_name" originator-name
          "recipient_name"  recipient-name
          "issue_date"      issue-date))]
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

(defun build-event (entity req action sys-name)
  (cc:infof (sorted-map "event" (sorted-map
    "oid" (get entity "claim_id")
    "key" (mk-uuid)
    "pdc" "private"
    "msp" "Org1MSP"
    "sys" sys-name
    "eng" action
    "req" req)) "event for {}" sys-name)
  (sorted-map
    "oid" (get entity "claim_id")
    "key" (mk-uuid)
    "pdc" "private"
    "msp" "Org1MSP"
    "sys" sys-name
    "eng" action
    "req" req))

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
                      (format-string "{}/{}" *SF_BASE_URL* sf-id)
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
         [req (mk-email-req "jack.clarke@luthersystems.com" subject body)])
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

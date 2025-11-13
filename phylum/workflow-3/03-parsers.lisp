(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; Parsers and Event Creators for Workflow 3 (Invoice → eSignature → Salesforce → Email)
;; -----------------------------------------------------------------------------

;; eSignature: create contract from template
(defun mk-esignature-create-contract-event (entity)
  (let* ([args (sorted-map
                 "template_id"      (or (get entity "template_id") *wf3-default-esig-template-id*)
                 "title"            (or (get entity "title")
                                        (format-string "Inter-Entity Invoice for Claim {}" (get entity "claim_id")))
                 "contract_source"  "mcpserver"
                 "mcp_query"        "Generate inter-entity invoice for signature"
                 "locale"           *wf3-default-esig-locale*
                 "expires_in_hours" *wf3-default-esig-expires-in-hours*
                 "test"             *wf3-default-esig-test-mode*
                 "labels"           *wf3-default-esig-labels*
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
  (let* ([m *wf3-default-sf-fields-map*]
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
                           "object_name" *wf3-default-sf-object-api*
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
    ;; extract useful data for later workflow steps
    (sorted-map
      "contract_id"   (and contract (get contract "id"))
      "sign_page_url" (and first-s (get first-s "sign_page_url"))
      "contract_status" (and contract (get contract "status")))))

;; Salesforce: parse create_record → {sf_record_id}
(defun parse-salesforce-create-record (resp)
  (let* ([decoded (parse-generic-resp resp)]
         [id      (get decoded "id")])
    (if id
      (sorted-map "sf_record_id" id)
      (set-exception-business "Salesforce did not return an id"))))

;; SMTP: parse generic ok response
(defun parse-smtp-send (resp)
  (let* ([j (parse-generic-resp resp)])
    (or j (sorted-map "status" "OK"))))
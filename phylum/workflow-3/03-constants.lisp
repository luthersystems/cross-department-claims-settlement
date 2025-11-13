(in-package 'sandbox)

;; -----------------------------------------------------------------------------
;; Constants for Workflow 3 (Invoice/eSignature/Salesforce/Email)
;; -----------------------------------------------------------------------------

;; Default invoice details
(set '*wf3-default-originator-name* "Acme Insurance Ltd.")
(set '*wf3-default-recipient-name* "BlueRiver Underwriting Partners")
(set '*wf3-default-issue-date* "2025-11-12")

;; eSignature defaults
(set '*wf3-default-esig-template-id* "91550d63-d436-43bb-9068-a39b46a0e005")
(set '*wf3-default-esig-locale* "en-GB")
(set '*wf3-default-esig-test-mode* "yes")
(set '*wf3-default-esig-expires-in-hours* "336")
(set '*wf3-default-esig-labels* (vector "inter-entity" "settlement"))
(set '*wf3-default-esig-custom-webhook-url* "")

;; Salesforce defaults
(set '*wf3-default-sf-object-api* "Settlement_Invoice__c")
(set '*wf3-default-sf-fields-map* (sorted-map
  "name"           "Name__c"
  "claim_id"       "Claim_ID__c"
  "contract_id"    "Contract_ID__c"
  "amount"         "Amount__c"
  "status"         "Status__c"
  "sign_url"       "esignature_sign_page_url__c"
  "invoice_amount" "invoice_amount__c"
  "signer_name"    "signer_name__c"))
(set '*wf3-default-sf-base-url* "https://orgfarm-cc0b69f3bb-dev-ed.develop.my.salesforce.com")

;; Email defaults
(set '*wf3-default-email-subject-template* "Settlement Invoice {{claim_id}} Sent for Signature")
(set '*wf3-default-email-body-template*
     (concat 'string
       "Hi {{signer_name}},\n\n"
       "The inter-entity settlement invoice for claim {{claim_id}} has been generated and sent for signature via eSignature.\n\n"
       "View in Salesforce: {{sf_record_url}}\n\n"
       "— ConnectorHub Automation"))
(set '*wf3-default-email-from* "ap@acme.example")
(set '*wf3-default-email-to* "jack.clarke@luthersystems.com")


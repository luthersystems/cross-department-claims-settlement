;; Copyright © 2025 Luther Systems, Ltd. All right reserved.
;; ----------------------------------------------------------------------------
;; The steps of the claim flow (claim.lisp): for each connector call, a
;; function that builds the event and a function that reads the reply.
;;
;; They are plain functions with no flow context, so the unit tests in
;; claim-steps_test.lisp call them directly, and claim.lisp reads as the
;; process alone.  A reader raises an error when a reply lacks what the
;; next step needs; the flow's `reply` macro turns that error into a failed
;; run with the reason (see claim.lisp).
;;
;; An await-connector reply arrives already decoded: the runtime parses the
;; connector's generic text as JSON, so a reader takes the JSON value.
;; ----------------------------------------------------------------------------
(in-package 'cdcs)

;; ---------------------------------------------------------------------------
;; Demo settings.  This example runs against mocked connectors
;; (fabric/connectorhub.yaml), so these name records in the demo tenants.
;; ---------------------------------------------------------------------------

;; Equifax needs a postal code and country that the claim record lacks.
(set 'equifax-postal-code "SW1A")
(set 'equifax-country-code "GB")

;; The SharePoint file that holds the claimant's ID verification.
;; The settlement document is in the same document library, but each claim
;; names its own file (see settlement-document-file).
(set 'claim-documents-site-id "samwoodluthersystems.sharepoint.com,af554837-6d2d-48e7-aa08-9584e15df76e,28227d76-23e6-4218-85c5-0473c0006245")
(set 'claim-documents-drive-id "b!N0hVry1t50iqCJWE4V33bnZ9IijmIxhChcUEc8AAYkU0cfiPk4MZRaBijb338Qw8")
(set 'id-document-file (sorted-map
                    "site_id"  claim-documents-site-id
                    "drive_id" claim-documents-drive-id
                    "item_id"  "01RAAXWAZH6LCSA5FLHRE2QJXBSIVDOGV4"
                    "filename" "id-verification.txt"))

;; Invoice defaults used when the start request leaves a field out.
(set 'default-originator-name "Acme Insurance Ltd.")
(set 'default-recipient-name "BlueRiver Underwriting Partners")
(set 'default-issue-date "2025-11-12")

(set 'esignature-template-id "91550d63-d436-43bb-9068-a39b46a0e005")
(set 'salesforce-base-url "https://orgfarm-cc0b69f3bb-dev-ed.develop.my.salesforce.com")
;; The finance inbox that hears about each invoice sent for signature.
(set 'invoice-email-to "jack.clarke@luthersystems.com")

(set 'zoho-customer-id "7533684000000109011")
(set 'zoho-due-date "2025-11-15")

;; The claim's currency, for the Zoho invoice and the SAP payment record.
(set 'claim-currency "GBP")

;; The D365FO and SAP payment records.  The payment id comes from the
;; payment-status input; the rest are the demo ledger's values.
(set 'payment-defaults (sorted-map
                         "invoice_id"     "INV-1002"
                         "reference"      "Batch-Nov-01"
                         "vendor_id"      "VEND-001"
                         "currency"       claim-currency
                         "payment_method" "EFT"
                         "payment_date"   "2025-11-06"))

;; ---------------------------------------------------------------------------
;; The start request
;; ---------------------------------------------------------------------------

(set 'claim-required-fields
     (vector "policy_id" "guidewire_claim_id" "invoice_amount" "signer_name" "signer_email"
             "settlement_document_item_id" "settlement_document_filename"))

;; Return why a start request cannot start a claim, or nil.  The flow calls
;; this before its first await, so a bad request fails the start with this
;; reason and writes no run.
(defun claim-request-problem (req)
  (let ([missing (select 'vector
                         (lambda (k) (blank? (get req k)))
                         claim-required-fields)])
    (cond
      ((not (empty? missing))
       (format-string "missing {}" (string:join (map 'list to-string missing) ", ")))
      ((nil? (amount-number (get req "invoice_amount")))
       (format-string "invoice_amount {} is not a positive decimal amount" (get req "invoice_amount")))
      ;; The demo once fetched the ID document a second time as the
      ;; settlement document (#37), so ServiceNow reviewers saw the wrong
      ;; file.  The two are separate documents; a request that names the
      ;; ID document as the settlement document is that mistake again.
      ((equal? (string:trim-space (to-string (get req "settlement_document_item_id")))
               (get id-document-file "item_id"))
       "settlement_document_item_id names the ID verification document, not a settlement document")
      (else ()))))

;; Return v as a positive float, or nil.  The Zoho step needs a number, and
;; it runs in a reply transaction where an error would leave the run
;; waiting, so the start checks the amount once.  Only plain decimal text
;; passes: Zoho gets the number and SAP and Salesforce get the text, so a
;; form that only a float parser reads ("Inf", "0x1p4", "1e3") would make
;; them record different amounts, and Inf cannot go into a JSON event.
(set 'decimal-amount (regexp:regexp-compile "^[0-9]+(\\.[0-9]+)?$"))

(defun amount-number (v)
  (when (and (string? v) (regexp:regexp-match? decimal-amount v))
    (let ([n (to-float v)])
      (when (> n 0) n))))

(defun blank? (v)
  (or (nil? v) (and (string? v) (empty? (string:trim-space v)))))

;; The claim the steps share: the request with the defaults filled in, and
;; the run id as the claim id.  The run id names the claim in every system
;; and in the input endpoints, so there is one id to look up.
(defun new-claim (claim-id req)
  (sorted-map
    "claim_id"           claim-id
    "policy_id"          (get req "policy_id")
    "guidewire_claim_id" (get req "guidewire_claim_id")
    "amount"             (get req "invoice_amount")
    "signer_name"        (get req "signer_name")
    "signer_email"       (get req "signer_email")
    "originator_name"    (or-default (get req "originator_name") default-originator-name)
    "recipient_name"     (or-default (get req "recipient_name") default-recipient-name)
    "issue_date"         (or-default (get req "issue_date") default-issue-date)
    "settlement_document_item_id"  (string:trim-space (to-string (get req "settlement_document_item_id")))
    "settlement_document_filename" (string:trim-space (to-string (get req "settlement_document_filename")))))

;; Return fallback when v is nil or blank: a JSON client often sends "" for "not set".
(defun or-default (v fallback)
  (if (blank? v) fallback v))

;; Build a connector event.  sys is the connector's id in
;; fabric/connectorhub.yaml.  The runtime adds the step key as the event's
;; idempotency key, so a resend cannot run the operation twice.
(defun claim-event (sys what req)
  (connector:mk-event sys req :msp "Org1MSP" :eng what))

(defun generic-req (kind operation args)
  (connector:mk-connector-req (sorted-map "kind" kind "operation" operation "args" args)))

;; A copy of map m with each key and value in kvs set.
(defun with-fields (m &rest kvs)
  (if (empty? kvs)
    m
    (apply with-fields (assoc m (first kvs) (second kvs)) (rest (rest kvs)))))

;; Raise the error a reader raises for a reply it cannot use.
(defun bad-reply (format &rest args)
  (error 'bad-reply (apply format-string format args)))

;; ---------------------------------------------------------------------------
;; WF1: Oracle claim record, Equifax screening, Teams thread
;; ---------------------------------------------------------------------------

;; The policy id is a bound value (:1), never SQL text, so it needs no quoting.
(defun oracle-claim-event (claim)
  (claim-event "oracle" "get claim"
    (generic-req "KIND_ORACLE_READONLY" "execute_query"
      (sorted-map
        "sql"  "SELECT CLAIM_ID, POLICY_ID, AMOUNT, STATUS, CLAIMANT_FIRST_NAME, CLAIMANT_LAST_NAME, CLAIMANT_DOB, CLAIMANT_ADDRESS, CLAIMANT_NATIONAL_ID FROM CLAIMS WHERE POLICY_ID = :1"
        "args" (vector (get claim "policy_id"))))))

;; The invoice may not ask for more than the claim is for (#37): the demo
;; once paid an invoice of 25000.00 on an Oracle claim of 2500.00.  So the
;; reader refuses a record whose AMOUNT is less than the invoice, before the
;; flow screens the claimant or writes anywhere.
(defun parse-oracle-claim (reply invoice-amount)
  (match reply
    ((sorted-map "rows" (vector row &rest _))
     (let ([(sorted-map "CLAIM_ID" id "AMOUNT" amount "STATUS" status
                        "CLAIMANT_FIRST_NAME" first-name "CLAIMANT_LAST_NAME" last-name
                        "CLAIMANT_DOB" dob "CLAIMANT_ADDRESS" address
                        "CLAIMANT_NATIONAL_ID" national-id) row])
       (check-within invoice-amount amount "the Oracle claim amount")
       (sorted-map "claim_id" id "amount" amount "status" status
                   "claimant" (sorted-map "first_name" first-name "last_name" last-name "dob" dob
                                          "address" address "national_id" national-id))))
    (_ (bad-reply "Oracle has no claim for this policy"))))

;; Equifax takes its own typed request, not a generic one.
(defun equifax-event (claim claimant)
  (claim-event "equifax" "verify claimant"
    (sorted-map "equifax"
      (sorted-map "entity_screening_request"
        (sorted-map "entity_id"            (get claim "claim_id")
                    "first_name"           (get claimant "first_name")
                    "last_name"            (get claimant "last_name")
                    "birth_date"           (get claimant "dob")
                    "address"              (get claimant "address")
                    "postal_code"          equifax-postal-code
                    "address_country_code" equifax-country-code
                    "federal_id"           (get claimant "national_id"))))))

;; Equifax wraps its answer differently by endpoint and version.
(defun parse-screening (reply)
  (let ([r (match reply
             ((sorted-map "equifax" (sorted-map "entity_screening_response" r)) r)
             ((sorted-map "entity_screening_response" r) r)
             ((sorted-map "entity_screening_response_nested" r) r)
             (_ reply))])
    (unless (sorted-map? r) (bad-reply "Equifax returned no screening"))
    (sorted-map "status"      (get r "status")
                "pstatus_det" (get r "pstatus_det")
                "hit_pep"     (or-default (get r "hit_value_pep") 0)
                "hit_emb"     (or-default (get r "hit_value_emb") 0))))

;; A screening passes when Equifax marks the person "Clear" and finds no PEP
;; (politically exposed person) or embargo hit.  Anything else goes to a
;; person: the Teams thread says why, and the claim goes on, because the
;; review happens in Teams, not in this flow.
(defun screening-concern (screening)
  (match screening
    ((sorted-map "pstatus_det" "Clear" "hit_pep" 0 "hit_emb" 0) ())
    ((sorted-map "pstatus_det" "Clear" "hit_pep" pep "hit_emb" emb)
     (format-string "{} PEP and {} embargo hits" pep emb))
    (_ (format-string "screening status {}" (or-default (get screening "pstatus_det") "missing")))))

(defun teams-thread-event (claim screening)
  (let ([concern (screening-concern screening)])
    (claim-event "teams" "start thread"
      (generic-req "KIND_MICROSOFT_TEAMS" "start_thread"
        (if concern
          (sorted-map "title"   "Equifax Screening Alert"
                      "content" (format-string "Claim {} flagged for review: {}" (get claim "claim_id") concern))
          (sorted-map "title"   "Equifax Screening Passed"
                      "content" (format-string "Claim {} successfully verified with Equifax." (get claim "claim_id"))))))))

(defun parse-teams-thread (reply)
  (match reply
    ((sorted-map "thread_id" thread "message_id" message) (sorted-map "thread_id" thread "message_id" message))
    (_ (bad-reply "Teams returned no thread"))))

;; ---------------------------------------------------------------------------
;; WF2: Guidewire claim, MySQL policy check, SharePoint ID document,
;; Guidewire approval
;; ---------------------------------------------------------------------------

(defun guidewire-claim-event (claim)
  (claim-event "outboundgw" "get claim"
    (generic-req "KIND_HTTP_OUTBOUND_REST" "getClaimDetails"
      (sorted-map "claim_id" (get claim "guidewire_claim_id")))))

(defun parse-guidewire-claim (reply)
  (match reply
    ((sorted-map "status" status)
     (unless (settleable-guidewire-status? status)
       (bad-reply "Guidewire claim status {} cannot be settled" status))
     (sorted-map "status" status "handler" (get reply "handler")))
    (_ (bad-reply "Guidewire returned no claim status"))))

;; The Guidewire claim statuses (the OUTBOUNDGW spec in
;; fabric/connectorhub.yaml) from which a claim may go on to settlement.
;; Rejected and Closed are final decisions in Guidewire, and the flow once
;; marked such a claim ApprovedForSettlement and paid it (#37).  The flow
;; approves the claim itself in a later step, so a claim still Open or
;; UnderReview may settle.  A status not on this list, including one a later
;; Guidewire version adds, stops the claim: paying on a status nobody has
;; judged is the mistake this check exists to prevent.
(set 'settleable-guidewire-statuses (vector "Open" "UnderReview" "Approved"))

(defun settleable-guidewire-status? (status)
  (not (empty? (select 'vector (lambda (s) (equal? s status)) settleable-guidewire-statuses))))

(defun policy-check-event (claim)
  (claim-event "mysql" "check policy"
    (generic-req "KIND_MYSQL" "mysql_query"
      (sorted-map
        "sql"  "SELECT POLICY_ID, STATUS, COVERAGE_LIMIT FROM policies WHERE POLICY_ID = ? AND STATUS = 'Active' LIMIT 1"
        "args" (vector (get claim "policy_id"))))))

;; The query asks only for an active policy, so no row means the claim's
;; policy is not active.  The invoice may not exceed the policy's coverage
;; limit (#37): the demo once paid 25000.00 against a 20000.00 limit.
(defun parse-active-policy (reply invoice-amount)
  (match reply
    ((vector (sorted-map "STATUS" status "COVERAGE_LIMIT" limit) &rest _)
     (check-within invoice-amount limit "the policy's coverage limit")
     (sorted-map "status" status "coverage_limit" limit))
    (_ (bad-reply "the policy is not active"))))

;; Raise a bad reply unless invoice-amount (the start request's decimal
;; text) is at most the cap a connector returned.  Both the claim amount
;; and the coverage limit apply, so the invoice is held to the lower one.
;; A cap that is missing or not a number stops the claim: without it the
;; flow cannot show the payment is covered.
(defun check-within (invoice-amount cap what)
  (let ([n (cap-number cap)])
    (when (nil? n) (bad-reply "{} is not an amount: {}" what cap))
    (when (> (amount-number invoice-amount) n)
      (bad-reply "invoice_amount {} exceeds {} {}" invoice-amount what cap))))

;; A cap as a database returns it: a JSON number (Oracle NUMBER) or decimal
;; text (MySQL DECIMAL).  Zero is a cap (nothing is covered); a negative
;; number or other text is not an amount.
(defun cap-number (v)
  (cond
    ((number? v) (when (>= v 0) (to-float v)))
    ((and (string? v) (regexp:regexp-match? decimal-amount v)) (to-float v))
    (else ())))

(defun id-document-event ()
  (claim-event "sharepoint" "get id-verification content"
    (generic-req "KIND_MICROSOFT_SHAREPOINT" "get_document_content" id-document-file)))

;; The ID document must be text that names the claim as Oracle knows it.
;; Its lines arrive base64-encoded.
(defun parse-id-document (reply oracle-claim-id)
  (match reply
    ((sorted-map "type" "text" "content" lines)
     (let ([text (string:join (map 'list (lambda (line) (to-string (base64:decode line))) lines) "\n")])
       (unless (names-id? text (to-string oracle-claim-id))
         (bad-reply "the ID document does not name claim {}" oracle-claim-id))
       (sorted-map "file" (get id-document-file "filename") "lines" (length lines))))
    (_ (bad-reply "the ID document is not text"))))

;; True when id appears in text as a whole word, so claim CLM-456 does not
;; match a document for CLM-4567, nor claim 12 the date 2025-11-12.  A word
;; is a run of letters, digits, _ and -.  An id with other characters
;; matches nothing: it is not a word, and it would need escaping.
(set 'word-id (regexp:regexp-compile "^[A-Za-z0-9_-]+$"))

(defun names-id? (text id)
  (and (regexp:regexp-match? word-id id)
       (regexp:regexp-match?
         (regexp:regexp-compile (format-string "(^|[^A-Za-z0-9_-]){}($|[^A-Za-z0-9_-])" id))
         text)))

(defun guidewire-approval-event (claim)
  (claim-event "outboundgw" "update approval"
    (generic-req "KIND_HTTP_OUTBOUND_REST" "updateClaimApproval"
      ;; Field names as the OpenAPI spec of OUTBOUNDGW declares them
      ;; (fabric/connectorhub.yaml): claim_id fills the path.
      (sorted-map "claim_id"    (get claim "guidewire_claim_id")
                  "approval"    "ApprovedForSettlement"
                  "approved_by" "Handler"))))

;; Guidewire may answer Rejected or Escalated; only ApprovedForSettlement
;; lets the claim go on to the invoice.
(defun parse-guidewire-approval (reply)
  (match reply
    ((sorted-map "approval" "ApprovedForSettlement") "ApprovedForSettlement")
    ((sorted-map "approval" approval) (bad-reply "Guidewire did not approve the claim: {}" approval))
    (_ (bad-reply "Guidewire did not confirm the approval"))))

;; ---------------------------------------------------------------------------
;; WF3: eSignature contract, Salesforce invoice, email to finance
;; ---------------------------------------------------------------------------

(defun esignature-event (claim)
  (claim-event "esignature" "create invoice contract"
    (generic-req "KIND_ESIGNATURES" "create_contract"
      (sorted-map
        "template_id"        esignature-template-id
        "title"              (format-string "Inter-Entity Invoice for Claim {}" (get claim "claim_id"))
        "contract_source"    "mcpserver"
        "mcp_query"          "Generate inter-entity invoice for signature"
        "locale"             "en-GB"
        "expires_in_hours"   "336"
        "test"               "yes"
        "labels"             (vector "inter-entity" "settlement")
        "placeholder_fields" (map 'vector
                                  (lambda (k) (sorted-map "api_key" k "value" (get claim k)))
                                  (vector "claim_id" "originator_name" "recipient_name" "issue_date" "amount"))
        "signers"            (vector (sorted-map "name"  (get claim "signer_name")
                                                 "email" (get claim "signer_email")
                                                 "signature_request_delivery_methods" (vector "email")
                                                 "signed_document_delivery_method"    "email"))
        "emails"             (sorted-map
                               "signature_request_subject" "Action Required: Review & Sign Inter-Entity Invoice"
                               "signature_request_text"    "Dear __FULL_NAME__,\n\nPlease review and sign the inter-entity settlement invoice."
                               "final_contract_subject"    "Invoice Signed Successfully"
                               "final_contract_text"       "Thank you, __FULL_NAME__, your contract has been signed and archived.")))))

(defun parse-esignature-contract (reply)
  (match reply
    ((sorted-map "data" (sorted-map "data" (sorted-map "contract" (sorted-map "id" id "status" status "signers" signers))))
     (sorted-map "contract_id" id
                 "status"      status
                 "sign_url"    (match signers
                                 ((vector (sorted-map "sign_page_url" url) &rest _) url)
                                 (_ ()))))
    (_ (bad-reply "eSignature returned no contract"))))

(defun salesforce-invoice-event (claim contract)
  (claim-event "salesforce" "create sf invoice"
    (generic-req "KIND_SALESFORCE" "create_record"
      (sorted-map
        "object_name" "Settlement_Invoice__c"
        "data" (sorted-map
                 "Name__c"                     (format-string "Inter-Entity Invoice {}" (get claim "claim_id"))
                 "Claim_ID__c"                 (get claim "claim_id")
                 "Contract_ID__c"              (get contract "contract_id")
                 "Amount__c"                   (get claim "amount")
                 "Status__c"                   "AwaitingSignature"
                 "esignature_sign_page_url__c" (get contract "sign_url")
                 "invoice_amount__c"           (get claim "amount")
                 "signer_name__c"              (get claim "signer_name"))))))

(defun parse-salesforce-record-id (reply)
  (match reply
    ((sorted-map "id" id) id)
    (_ (bad-reply "Salesforce returned no record id"))))

;; Teams answers with a status; the email connector's reply has no fields.
;; A reply with an error or a failed status means the message did not go,
;; and the next step would wait on someone who was never told.  A send the
;; hub could not make comes back as a connector error, which fails the run.
(defun parse-sent (reply)
  (match reply
    ((sorted-map "error" err) (bad-reply "the message was not sent: {}" err))
    ((sorted-map "status" status)
     (when (let ([st (string:lowercase (to-string status))]) (or (equal? st "failed") (equal? st "error")))
       (bad-reply "the message was not sent: status {}" status))
     status)
    (_ "sent")))

(defun invoice-email-event (claim sf-record-id)
  (let ([claim-id (get claim "claim_id")])
    (claim-event "email" "dispatch invoice email"
      (connector:mk-email-req
        invoice-email-to
        (format-string "Settlement Invoice {} Sent for Signature" claim-id)
        (string:join
          (list "Hello,"
                ""
                (format-string "The inter-entity settlement invoice for claim {} has been generated" claim-id)
                "and sent for signature via eSignature."
                ""
                (format-string "View in Salesforce: {}/{}" salesforce-base-url sf-record-id)
                ""
                "— ConnectorHub Automation")
          "\n")))))

;; ---------------------------------------------------------------------------
;; WF4: Zoho invoice, SharePoint document, ServiceNow incident
;; ---------------------------------------------------------------------------

(defun zoho-invoice-event (claim)
  ;; One line item for the claim amount, in the claim currency, so Zoho,
  ;; the payment notice and SAP agree.
  (claim-event "zoho" "create invoice"
    (generic-req "KIND_ZOHO_BOOKS" "create_invoice"
      (sorted-map "json_data"
        (sorted-map "customer_id"      zoho-customer-id
                    "reference_number" (get claim "claim_id")
                    "due_date"         zoho-due-date
                    "is_inclusive_tax" true
                    "currency_code"    claim-currency
                    "line_items"       (vector (sorted-map "name"     "Inter-Entity Settlement"
                                                           "rate"     (amount-number (get claim "amount"))
                                                           "quantity" 1)))))))

(defun parse-zoho-invoice (reply)
  (match reply
    ((sorted-map "invoice" (sorted-map "invoice_id" id "invoice_number" number "total" total))
     (sorted-map "invoice_id" id "invoice_number" number "total" total))
    (_ (bad-reply "Zoho returned no invoice"))))

(defun settlement-document-event (claim)
  (claim-event "sharepoint" "get sharepoint doc"
    (generic-req "KIND_MICROSOFT_SHAREPOINT" "get_document_content" (settlement-document-file claim))))

;; The claim's settlement document, as the start request names it.  There is
;; no one settlement document for every claim the way there is one demo ID
;; document, so the caller that starts the claim says which file it is.
;; get_document_content picks its parser by the filename's extension, so the
;; filename is required with the item id.
(defun settlement-document-file (claim)
  (sorted-map "site_id"  claim-documents-site-id
              "drive_id" claim-documents-drive-id
              "item_id"  (get claim "settlement_document_item_id")
              "filename" (get claim "settlement_document_filename")))

;; The settlement document is fetched for the incident's reviewers; the
;; flow keeps only what it is.
(defun parse-document (reply filename)
  (match reply
    ((sorted-map "type" kind) (sorted-map "file" filename "type" kind "lines" (get reply "line_count")))
    (_ (bad-reply "SharePoint returned no document"))))

(defun servicenow-incident-event (claim)
  (claim-event "servicenow" "create incident"
    (generic-req "KIND_SERVICENOW" "create_incident"
      (sorted-map "short_description" (format-string "Create incident for claim {}" (get claim "claim_id"))
                  "description"       "Auto-generated incident for inter-entity settlement review"
                  "priority"          "3"
                  "category"          "Finance"
                  "impact"            "2"
                  "urgency"           "2"
                  "assignment_group"  "Finance Ops"))))

(defun parse-servicenow-incident (reply)
  (match reply
    ((sorted-map "result" (sorted-map "number" number "sys_id" id)) (sorted-map "number" number "sys_id" id))
    ((sorted-map "incident_number" number "incident_id" id) (sorted-map "number" number "sys_id" id))
    (_ (bad-reply "ServiceNow returned no incident"))))

;; ---------------------------------------------------------------------------
;; Payment: Teams notice, D365FO journal, SAP HANA record
;; ---------------------------------------------------------------------------

(defun payment-notice-event (claim thread invoice)
  (claim-event "teams" "update thread"
    (generic-req "KIND_MICROSOFT_TEAMS" "update_thread"
      (sorted-map
        "thread_id"  (get thread "thread_id")
        "message_id" (get thread "message_id")
        "content"    (format-string
                       "Claim payment request\n\nClaim ID: {}\nPolicy ID: {}\nAmount: {}\nInvoice: {}\nStatus: claim approved, invoice generated, contract signed\n\nPlease review and approve payment for this claim."
                       (get claim "claim_id") (get claim "policy_id") (get claim "amount")
                       (get invoice "invoice_number"))))))

(defun d365fo-journal-event (payment)
  (claim-event "d365fo" "create d365fo payment journal"
    (generic-req "KIND_D365_FO" "d365fo_create_entity_record"
      (sorted-map
        "entity_name"   "JournalNames"
        "return_record" true
        "profile"       "default"
        "data"          (sorted-map
                          "dataAreaId"        "DAT"
                          "Name"              (format-string "{}-AP-PAY" (get payment "vendor_id"))
                          "Type"              "Payment"
                          "Description"       (format-string "AP payments - {} - {}" (get payment "reference") (get payment "invoice_id"))
                          "VoucherSeriesCode" "VOUCHER")))))

;; The journal's record id is the D365FO transaction id that SAP records.
(defun parse-d365fo-journal (reply)
  (let ([record (match reply
                  ((sorted-map "record" r) r)
                  ((sorted-map "data" r) r)
                  (_ reply))])
    (match record
      ((sorted-map "RecId" id) (to-string id))
      ((sorted-map "transaction_id" id) (to-string id))
      (_ (bad-reply "D365FO returned no journal record id")))))

;; Every value is bound (?), never SQL text.  SAP HANA refuses a null bound
;; value, so each one must be present.
(defun sap-payment-event (payment amount d365fo-txn-id)
  (claim-event "sap" "record payment in sap hana"
    (generic-req "KIND_SAP_HANA" "hana_execute_query"
      (sorted-map
        "query" "INSERT INTO PAYMENTS_STAGING (PAYMENT_ID, INVOICE_ID, REFERENCE, VENDOR_ID, AMOUNT, CURRENCY, PAYMENT_METHOD, PAYMENT_DATE, STATUS, D365FO_TXN_ID) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        "args"  (vector (get payment "payment_id") (get payment "invoice_id") (get payment "reference")
                        (get payment "vendor_id") amount (get payment "currency")
                        (get payment "payment_method") (get payment "payment_date")
                        (get payment "status") d365fo-txn-id)))))

;; The payment as ABS reported it, with the demo ledger's fields.
(defun payment-record (status-input)
  (with-fields payment-defaults
               "payment_id" (get status-input "payment_id")
               "status"     (get status-input "status")))

(defun parse-sap-payment (reply)
  (match reply
    ((sorted-map "payment" p) (get p "transaction_id"))
    ((sorted-map "rows_affected" n) (format-string "{} row(s)" n))
    (_ (bad-reply "SAP HANA did not confirm the payment record"))))

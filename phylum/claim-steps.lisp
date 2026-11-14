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
     (vector "policy_id" "oracle_claim_id" "guidewire_claim_id" "invoice_amount" "signer_name" "signer_email"
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
      ((or (nil? (amount-number (get req "invoice_amount")))
           (nil? (amount-cents (get req "invoice_amount"))))
       (format-string "invoice_amount {} is not a positive decimal amount" (get req "invoice_amount")))
      ;; The demo once fetched the ID document a second time as the
      ;; settlement document (#37), so ServiceNow reviewers saw the wrong
      ;; file.  The two are separate documents; a request that names the
      ;; ID document as the settlement document is that mistake again.
      ;; Compared without case: SharePoint takes an item id in either case.
      ((equal? (string:lowercase (string:trim-space (to-string (get req "settlement_document_item_id"))))
               (string:lowercase (get id-document-file "item_id")))
       "settlement_document_item_id names the ID verification document, not a settlement document")
      (else ()))))

;; Return v as a positive float, or nil.  The Zoho step needs a number, and
;; it runs in a reply transaction where an error would leave the run
;; waiting, so the start checks the amount once.  Only plain decimal text
;; passes: Zoho gets the number and SAP and Salesforce get the text, so a
;; form that only a float parser reads ("Inf", "0x1p4", "1e3") would make
;; them record different amounts, and Inf cannot go into a JSON event.
;; At most two decimal places, as GBP has: the coverage checks compare the
;; amount as a float, and "20000.000000000000001" would round to the
;; 20000.00 limit and pass while SAP recorded the longer text.
(set 'decimal-amount (regexp:regexp-compile "^[0-9]+(\\.[0-9]{1,2})?$"))

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
    "policy_id"          (string:trim-space (to-string (get req "policy_id")))
    "oracle_claim_id"    (string:trim-space (to-string (get req "oracle_claim_id")))
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

;; The start request names the Oracle claim (#39).  The lookup once took the
;; first claim Oracle returned for the policy, so with two claims on a policy
;; the invoice was held to, and the ID document checked against, whichever
;; came first.  The ids are bound values (:1, :2), never SQL text, so they
;; need no quoting.
(defun oracle-claim-event (claim)
  (claim-event "oracle" "get claim"
    (generic-req "KIND_ORACLE_READONLY" "execute_query"
      (sorted-map
        "sql"  "SELECT CLAIM_ID, POLICY_ID, AMOUNT, STATUS, CLAIMANT_FIRST_NAME, CLAIMANT_LAST_NAME, CLAIMANT_DOB, CLAIMANT_ADDRESS, CLAIMANT_NATIONAL_ID FROM CLAIMS WHERE CLAIM_ID = :1 AND POLICY_ID = :2"
        "args" (vector (get claim "oracle_claim_id") (get claim "policy_id"))))))

;; The only Oracle claim status that may settle (#39).  The flow once settled
;; a claim Oracle had closed because Guidewire still said Open.
(set 'settleable-oracle-status "Open")

;; The reply must be the one claim the request names, on the request's
;; policy, and Open.  The query asks for exactly that, so the reader checks
;; the row too: a reply for another claim would hold the invoice to the
;; wrong amount.
;;
;; The invoice may not ask for more than the claim is for (#37): the demo
;; once paid an invoice of 25000.00 on an Oracle claim of 2500.00.  Nor may
;; it, with what earlier runs settled on this claim, ask for more (#39):
;; two starts with different request keys could each pay the whole claim.
;; settled is that amount in pence (see settled-cents).  The reader refuses
;; before the flow screens the claimant or writes anywhere.
(defun parse-oracle-claim (reply oracle-claim-id policy-id invoice-amount settled)
  (match reply
    ((sorted-map "rows" (vector row))
     (let ([(sorted-map "CLAIM_ID" id "POLICY_ID" policy "AMOUNT" amount "STATUS" status
                        "CLAIMANT_FIRST_NAME" first-name "CLAIMANT_LAST_NAME" last-name
                        "CLAIMANT_DOB" dob "CLAIMANT_ADDRESS" address
                        "CLAIMANT_NATIONAL_ID" national-id) row])
       (unless (and (equal? (to-string id) oracle-claim-id) (equal? (to-string policy) policy-id))
         (bad-reply "Oracle returned claim {} on policy {}, not claim {} on policy {}"
                    id policy oracle-claim-id policy-id))
       (unless (equal? status settleable-oracle-status)
         (bad-reply "Oracle claim {} status {} cannot be settled" id status))
       (check-within invoice-amount settled amount "the Oracle claim amount")
       (sorted-map "claim_id" id "amount" amount "status" status
                   "claimant" (sorted-map "first_name" first-name "last_name" last-name "dob" dob
                                          "address" address "national_id" national-id))))
    ((sorted-map "rows" (vector)) (bad-reply "Oracle has no claim {} on policy {}" oracle-claim-id policy-id))
    ((sorted-map "rows" (vector &rest rows))
     (bad-reply "Oracle returned {} rows for claim {}" (length rows) oracle-claim-id))
    (_ (bad-reply "Oracle returned no claim rows"))))

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
;; Settled amounts (#39)
;;
;; The phylum records, in its own state, how much each Oracle claim and each
;; policy has settled, in pence.  The readers above hold each new invoice to
;; the claim amount and the coverage limit less what is recorded.  A run
;; adds its invoice before it asks the payment team to approve the payment
;; (reserve-settlement), not after ABS pays, so two runs in flight for the
;; same claim cannot both pass: the second sees the first's amount.  Each
;; run's reservation is one transaction that reads and writes both keys, so
;; Fabric's read-set check refuses one of two that race.  A rejected payment
;; gives its amount back (release-settlement).
;;
;; A run that fails or is cancelled after the payment notice went keeps its
;; amount recorded: the payment may already be with ABS, and an amount
;; wrongly held only blocks a later settlement, while an amount wrongly
;; released could pay a claim twice.  No endpoint releases such an amount
;; yet.  A notice that does not go releases it (claim.lisp).
;;
;; Known limits.  The readers check early, so a claim already settled stops
;; before anything is written, but only the reservation is binding: two
;; runs in flight both pass the readers and both write the Guidewire
;; approval, contract and invoices before one is refused at the
;; reservation.  On Fabric the two reservations race through the read-set
;; check: the loser's transaction is invalidated at commit, not refused
;; with a reason, and as the hub does not resend a reply the run waits out
;; its connector timeout.  The emulator runs them one after the other, so
;; the tests see the reason.
;; ---------------------------------------------------------------------------

(defun settled-key (kind id) (format-string "cdcs:settled:{}:{}" kind id))

;; The pence recorded as settled for an Oracle claim ("claim") or a policy
;; ("policy").  Stored as decimal text: statedb keeps JSON, and a JSON
;; number may come back as a float.
(defun settled-cents (kind id)
  (let ([v (statedb:get (settled-key kind id))])
    (if (nil? v) 0 (to-int v))))

(defun put-settled (kind id cents)
  (when (< cents 0)
    ;; Only a release of what this run reserved subtracts, so a negative
    ;; total is a bookkeeping bug.  Fail the transaction rather than hide it.
    (error 'settled-negative (format-string "settled amount for {} {} would be {} pence" kind id cents)))
  (statedb:put (settled-key kind id) (to-string cents)))

;; Record the claim's invoice as settled on its Oracle claim and its policy,
;; and return nil; or return why it does not fit, and record nothing.  The
;; checks are those of the readers, run again because another run may have
;; reserved since this one read its replies.
(defun reserve-settlement (claim record policy)
  (let* ([amount (get claim "amount")]
         [claim-id (get claim "oracle_claim_id")]
         [policy-id (get claim "policy_id")]
         [on-claim (settled-cents "claim" claim-id)]
         [on-policy (settled-cents "policy" policy-id)]
         [problem (or (cap-problem amount on-claim (get record "amount") "the Oracle claim amount")
                      (cap-problem amount on-policy (get policy "coverage_limit")
                                   "the policy's coverage limit"))])
    (unless problem
      (put-settled "claim" claim-id (+ on-claim (amount-cents amount)))
      (put-settled "policy" policy-id (+ on-policy (amount-cents amount))))
    problem))

;; Give back what reserve-settlement recorded for the claim.
(defun release-settlement (claim)
  (let ([cents (amount-cents (get claim "amount"))]
        [claim-id (get claim "oracle_claim_id")]
        [policy-id (get claim "policy_id")])
    (put-settled "claim" claim-id (- (settled-cents "claim" claim-id) cents))
    (put-settled "policy" policy-id (- (settled-cents "policy" policy-id) cents))))

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
;; limit (#37): the demo once paid 25000.00 against a 20000.00 limit.  The
;; limit covers every claim on the policy, so what earlier runs settled on
;; the policy counts too (#39); settled is that amount in pence.
(defun parse-active-policy (reply invoice-amount settled)
  (match reply
    ((vector (sorted-map "STATUS" status "COVERAGE_LIMIT" limit) &rest _)
     (check-within invoice-amount settled limit "the policy's coverage limit")
     (sorted-map "status" status "coverage_limit" limit))
    (_ (bad-reply "the policy is not active"))))

;; Raise a bad reply unless invoice-amount (the start request's decimal
;; text), with settled pence already settled, is at most the cap a
;; connector returned.  Both the claim amount and the coverage limit apply,
;; so the invoice is held to the lower one.
(defun check-within (invoice-amount settled cap what)
  (let ([problem (cap-problem invoice-amount settled cap what)])
    (when problem (bad-reply "{}" problem))))

;; Why invoice-amount and settled pence do not fit under cap, or nil.  A cap
;; that is missing or not a number stops the claim: without it the flow
;; cannot show the payment is covered.  Amounts are compared in whole pence,
;; so 0.10 settled and 0.20 invoiced fit a cap of 0.30.
(defun cap-problem (invoice-amount settled cap what)
  (let ([limit (cap-cents cap)]
        [invoice (amount-cents invoice-amount)])
    (cond
      ((nil? limit) (format-string "{} is not an amount: {}" what cap))
      ((nil? invoice) (format-string "invoice_amount {} is not an amount" invoice-amount))
      ((<= (+ invoice settled) limit) ())
      ((= settled 0) (format-string "invoice_amount {} exceeds {} {}" invoice-amount what cap))
      (else (format-string "invoice_amount {} with {} already settled exceeds {} {}"
                           invoice-amount (cents-text settled) what cap)))))

;; An invoice amount's text in pence, or nil.  The start request allows at
;; most two decimal places, so the text converts exactly.  More than 13
;; whole digits would not fit an int in pence and is no demo invoice.
(set 'pence-text (regexp:regexp-compile "^[0-9]{1,13}(\\.[0-9]{1,2})?$"))

(defun amount-cents (v)
  (when (and (string? v) (regexp:regexp-match? pence-text v))
    (let* ([parts (string:split v ".")]
           [frac (if (= (length parts) 2) (second parts) "0")])
      (+ (* 100 (to-int (first parts)))
         (if (= (length frac) 1) (* 10 (to-int frac)) (to-int frac))))))

;; A cap in whole pence, rounded down: a cap of 19.9999 covers 19.99.  A
;; cap arrives as a float or as text with any number of decimal places, so
;; its float times 100 may fall just short of a whole penny (19.99 * 100 is
;; 1998.9999999999998); the next penny counts when the cap reaches it.
;; A cap of a trillion pounds or more is no demo cap and is not an amount.
(defun cap-cents (v)
  (let ([n (cap-number v)])
    (when (and n (< n 1e12))
      (let ([c (to-int (* n 100))])
        (if (<= (/ (to-float (+ c 1)) 100) n) (+ c 1) c)))))

;; Pence as decimal text: 250010 is "2500.10".
(defun cents-text (c)
  (let ([p (mod c 100)])
    (format-string "{}.{}{}" (to-int (/ c 100)) (if (< p 10) "0" "") p)))

;; A cap as a database returns it: a JSON number (Oracle NUMBER) or decimal
;; text (MySQL DECIMAL).  Zero is a cap (nothing is covered); a negative
;; number or other text is not an amount.
;; A database may return more decimal places than an invoice may have
;; (DECIMAL(12,4)), so a cap's text may have any number of them.
(set 'decimal-text (regexp:regexp-compile "^[0-9]+(\\.[0-9]+)?$"))

(defun cap-number (v)
  (cond
    ((number? v) (when (>= v 0) (to-float v)))
    ((and (string? v) (regexp:regexp-match? decimal-text v)) (to-float v))
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
;; flow keeps only what it is.  When SharePoint names the file it read, it
;; must be the one the claim asked for: #37 was the ID document passed off
;; as the settlement document, and a summary that only echoed the request
;; would hide that.
(defun parse-document (reply filename)
  (match reply
    ((sorted-map "type" kind)
     (let ([returned (match (get reply "documents")
                   ((vector (sorted-map "file" f) &rest _) f)
                   (_ ()))])
       (when (and returned (not (equal? returned filename)))
         (bad-reply "SharePoint returned {}, not the settlement document {}" returned filename))
       (sorted-map "file" filename "type" kind "lines" (get reply "line_count"))))
    (_ (bad-reply "SharePoint returned no document"))))

(defun servicenow-incident-event (claim)
  (claim-event "servicenow" "create incident"
    (generic-req "KIND_SERVICENOW" "create_incident"
      ;; The description names the settlement document so the reviewers
      ;; open the right file in SharePoint.
      (sorted-map "short_description" (format-string "Create incident for claim {}" (get claim "claim_id"))
                  "description"       (format-string "Auto-generated incident for inter-entity settlement review.\nSettlement document: {} (SharePoint item {})"
                                                     (get claim "settlement_document_filename")
                                                     (get claim "settlement_document_item_id"))
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

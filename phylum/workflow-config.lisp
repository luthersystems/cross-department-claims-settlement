(in-package 'sandbox)

;; -----------------------------------------------------------------------------
;; Workflow Chaining Configuration & Helpers
;; -----------------------------------------------------------------------------
;; Central place to toggle workflow chaining behaviour and provide helper
;; utilities that can be shared across routes, workflows, and registrations.

;; -----------------------------------------------------------------------------
;; WF1 → WF2 chaining (Oracle/Equifax -> Guidewire/MySQL)
;; -----------------------------------------------------------------------------
(set '*wf1-chain-enabled* true)

(set '*wf1-wf2-default-inputs*
     (sorted-map
       "policy_id"        "POL-1001"
       "gw_claim_id"      "GW-1001"
       "signer_email"     "approver@example.com"
       "signer_name"      "Workflow Approver"
       "invoice_amount"   "25000.00"
       "originator_name"  "Acme Insurance Ltd."
       "recipient_name"   "BlueRiver Underwriting Partners"
       "issue_date"       "2025-11-05"
       "chain_to_wf3"     true))

;; -----------------------------------------------------------------------------
;; WF2 → WF3 chaining (Guidewire/MySQL/SP -> Invoice/Email)
;; -----------------------------------------------------------------------------
(set '*wf2-chain-enabled* true)

;; Optional default payload for invoking WF3 when chaining is enabled.
;; Set to () if you prefer to derive values dynamically from the WF2 entity.
(set '*wf2-wf3-default-inputs*
     (sorted-map
       "claim_id"        "CLM-4567"
       "invoice_amount"  "20000.00"
       "signer_name"     "Jack Clarke"
       "signer_email"    "jack.clarke@luthersystems.com"
       "originator_name" "Acme Insurance Ltd."
       "recipient_name"  "BlueRiver Underwriting Partners"
       "issue_date"      "2025-11-05"))

;; -----------------------------------------------------------------------------
;; WF3 → WF4 chaining (Invoice/Email -> Zoho/SharePoint/ServiceNow)
;; -----------------------------------------------------------------------------
(set '*wf3-chain-enabled* true)

(set '*wf3-wf4-default-inputs*
     (sorted-map
       "zoho" (sorted-map
                 "customer_id"      "7533684000000109011"
                 "reference_number" "CLAIM-8472"
                 "due_date"         "2025-11-17"
                 "is_inclusive_tax" true
                 "currency_code"    "GBP"
                 "line_items"       (vector (sorted-map
                                             "name"     "Inter-Entity Settlement"
                                             "rate"     1250.0
                                             "quantity" 1)))
       "sharepoint" (sorted-map
                      "site_id"  "samwoodluthersystems.sharepoint.com,af554837-6d2d-48e7-aa08-9584e15df76e,28227d76-23e6-4218-85c5-0473c0006245"
                      "drive_id" "b!N0hVry1t50iqCJWE4V33bnZ9IijmIxhChcUEc8AAYkU0cfiPk4MZRaBijb338Qw8"
                      "item_id"  "01RAAXWAZH6LCSA5FLHRE2QJXBSIVDOGV4"
                      "filename" "id-verification.txt")
       "servicenow" (sorted-map
                      "short_description" "Create ServiceNow incident for settlement invoice"
                      "description"      "Auto-generated incident for inter-entity settlement review"
                      "priority"         "3"
                      "category"         "Finance"
                      "impact"           "2"
                      "urgency"          "2"
                      "assignment_group" "Finance Ops")
       "chain_to_wf4" true
       "chain_to_wf5" true))

(defun normalize-bool (value &optional default-value)
  "Best-effort boolean coercion with sensible defaults."
  (cond
    ((nil? value) (if (nil? default-value) false default-value))
    ((equal? value true) true)
    ((equal? value false) false)
    ((string? value)
     (let* ([lower (string:downcase value)])
       (cond
         ((or (equal? lower "true")
              (equal? lower "1")
              (equal? lower "yes")
              (equal? lower "y")
              (equal? lower "on")) true)
         ((or (equal? lower "false")
              (equal? lower "0")
              (equal? lower "no")
              (equal? lower "n")
              (equal? lower "off")) false)
         (:else (if (nil? default-value) false default-value)))))
    (:else (if (nil? default-value) false default-value))))

(defun wf1-should-chain? (entity)
  "Determine whether WF1 should hand off to WF2 for the given entity."
  (normalize-bool (get entity "chain_to_wf2") *wf1-chain-enabled*))

(defun wf1-derive-wf2-inputs (entity parsed)
  "Build a payload for WF2 using WF1 entity data as a fallback."
  (let* ([policy-id (or (get entity "policy_id")
                        (set-exception-business "missing policy_id for WF2 handoff"))]
         [claim-id (or (get entity "claim_id")
                       (set-exception-business "missing claim_id for WF2 handoff"))]
         [gw-claim-id (or (get entity "gw_claim_id")
                          (get entity "guidewire_claim_id")
                          (format-string "GW-{}" claim-id))]
         [signer-email (get entity "signer_email")]
         [signer-name  (get entity "signer_name")]
         [invoice-amount (get entity "invoice_amount")] 
         [originator-name (or (get entity "originator_name") "Acme Insurance Ltd.")]
         [recipient-name  (or (get entity "recipient_name") "BlueRiver Underwriting Partners")]
         [issue-date      (or (get entity "issue_date")  "2025-11-12")]
         [chain-to-wf3    (normalize-bool (get entity "chain_to_wf3") *wf2-chain-enabled*)])
    (sorted-map
      "policy_id"        policy-id
      "gw_claim_id"      gw-claim-id
      "signer_email"     signer-email
      "signer_name"      signer-name
      "invoice_amount"   invoice-amount
      "originator_name"  originator-name
      "recipient_name"   recipient-name
      "issue_date"       issue-date
      "chain_to_wf3"     chain-to-wf3)))

(defun wf1-build-wf2-inputs (entity parsed)
  "Construct WF2 inputs, merging defaults with derived values from entity."
  (let* ([derived (wf1-derive-wf2-inputs entity parsed)]
         [defaults (or *wf1-wf2-default-inputs* (sorted-map))])
    ;; Merge defaults with derived, preferring derived values
    (sorted-map
      "policy_id"        (or (get derived "policy_id") (get defaults "policy_id"))
      "gw_claim_id"      (or (get derived "gw_claim_id") (get defaults "gw_claim_id"))
      "signer_email"     (or (get derived "signer_email") (get defaults "signer_email"))
      "signer_name"      (or (get derived "signer_name") (get defaults "signer_name"))
      "invoice_amount"   (or (get derived "invoice_amount") (get defaults "invoice_amount"))
      "originator_name"  (or (get derived "originator_name") (get defaults "originator_name"))
      "recipient_name"   (or (get derived "recipient_name") (get defaults "recipient_name"))
      "issue_date"       (or (get derived "issue_date") (get defaults "issue_date"))
      "chain_to_wf3"     (or (get derived "chain_to_wf3") (get defaults "chain_to_wf3")))))

(defun wf3-should-chain? (entity)
  "Determine whether WF3 should hand off to WF4 for the given entity."
  (normalize-bool (get entity "chain_to_wf4") *wf3-chain-enabled*))

(defun wf3-derive-wf4-inputs (entity parsed)
  "Build a payload for WF4 using WF3 entity data as a fallback."
  (let* ([claim-id (or (get entity "claim_id")
                       (set-exception-business "missing claim_id for WF4 handoff"))]
         [amount   (or (get entity "amount")
                       (get entity "invoice_amount")
                       (set-exception-business "missing invoice_amount for WF4 handoff"))]
         [defaults (or *wf3-wf4-default-inputs* (sorted-map))]
         [zoho-base       (or (get defaults "zoho") (sorted-map))]
         [sharepoint-base (or (get defaults "sharepoint") (sorted-map))]
         [servicenow-base (or (get defaults "servicenow") (sorted-map))]
         [chain-to-wf5    (normalize-bool (or (get defaults "chain_to_wf5") (get entity "chain_to_wf5")) true)]
         [line-items (or (get zoho-base "line_items")
                         (vector (sorted-map
                                   "name"     "Inter-Entity Settlement"
                                   "rate"     amount
                                   "quantity" 1)))]
         [zoho (sorted-map)]
         [zoho (assoc zoho "customer_id"      (or (get zoho-base "customer_id") "7533684000000109011"))]
         [zoho (assoc zoho "reference_number" (or (get zoho-base "reference_number") claim-id))]
         [zoho (assoc zoho "due_date"         (or (get zoho-base "due_date")  "2025-11-12"))]
         [zoho (assoc zoho "is_inclusive_tax" (normalize-bool (get zoho-base "is_inclusive_tax") true))]
         [zoho (assoc zoho "currency_code"    (or (get zoho-base "currency_code") "GBP"))]
         [zoho (assoc zoho "line_items"       line-items)]
         [sharepoint (sorted-map)]
         [sharepoint (assoc sharepoint "site_id" (or (get sharepoint-base "site_id")
                                                    "samwoodluthersystems.sharepoint.com,af554837-6d2d-48e7-aa08-9584e15df76e,28227d76-23e6-4218-85c5-0473c0006245"))]
         [sharepoint (assoc sharepoint "drive_id" (or (get sharepoint-base "drive_id")
                                                     "b!N0hVry1t50iqCJWE4V33bnZ9IijmIxhChcUEc8AAYkU0cfiPk4MZRaBijb338Qw8"))]
         [sharepoint (assoc sharepoint "item_id" (or (get sharepoint-base "item_id")
                                                    "01RAAXWAZH6LCSA5FLHRE2QJXBSIVDOGV4"))]
         [sharepoint (assoc sharepoint "filename" (or (get sharepoint-base "filename")
                                                     "id-verification.txt"))]
         [servicenow (sorted-map)]
         [servicenow (assoc servicenow "short_description" (or (get servicenow-base "short_description")
                                                               (format-string "Create incident for claim {}" claim-id)))]
         [servicenow (assoc servicenow "description"      (or (get servicenow-base "description")
                                                               (format-string "Invoice {} requires review" claim-id)))]
         [servicenow (assoc servicenow "priority"         (or (get servicenow-base "priority") "3"))]
         [servicenow (assoc servicenow "category"         (or (get servicenow-base "category") "Finance"))]
         [servicenow (assoc servicenow "impact"           (or (get servicenow-base "impact") "2"))]
         [servicenow (assoc servicenow "urgency"          (or (get servicenow-base "urgency") "2"))]
         [servicenow (assoc servicenow "assignment_group" (or (get servicenow-base "assignment_group") "Finance Ops"))]
         [servicenow (if (get servicenow-base "caller_id")
                         (assoc servicenow "caller_id" (get servicenow-base "caller_id"))
                         servicenow)]
         [chain-flag (normalize-bool (get defaults "chain_to_wf4") true)])
    (sorted-map
      "claim_id"    claim-id
      "policy_id"   (or (get entity "policy_id") "POL-8872")
      "zoho"        zoho
      "sharepoint"  sharepoint
      "servicenow"  servicenow
      "chain_to_wf4" chain-flag
      "chain_to_wf5" chain-to-wf5)))

(defun wf3-build-wf4-inputs (entity parsed)
  "Construct WF4 inputs, preferring configured defaults when provided."
  (wf3-derive-wf4-inputs entity parsed))

;; -----------------------------------------------------------------------------
;; WF4 → WF5 chaining (Zoho/SharePoint/ServiceNow -> SAP/NetSuite)
;; -----------------------------------------------------------------------------
(set '*wf4-chain-enabled* true)

(set '*wf4-wf5-default-inputs*
     (sorted-map
       "claim_id" "CLM-4567"
       "policy_id" "POL-8872"
       "sap" (sorted-map
                "payment_id"     "PAYM-1001"
                "invoice_id"     "INV-10001"
                "reference"      "Batch-Nov-02"
                "vendor_id"      "VEND-001"
                "amount"         2500.00
                "currency"       "USD"
                "payment_method" "EFT"
                "payment_date"   "2025-11-07"
                "status"         "PENDING")
       "netsuite" (sorted-map
                    "invoice_id" "INV-10001"
                    "amount"     2500.00
                    "currency"   "USD"
                    "memo"       "Inter-entity settlement reconciliation")
       "chain_to_wf5" true))

(defun wf4-should-chain? (entity)
  (normalize-bool (get entity "chain_to_wf5") *wf4-chain-enabled*))

(defun wf4-derive-wf5-inputs (entity parsed)
  (let* ([defaults (or *wf4-wf5-default-inputs* (sorted-map))]
         [claim-id (or (get entity "claim_id") (get defaults "claim_id")
                       (set-exception-business "missing claim_id for WF5 handoff"))]
         [policy-id (or (get entity "policy_id") (get defaults "policy_id")
                        (set-exception-business "missing policy_id for WF5 handoff"))]
         [sap (or (get entity "sap") (get defaults "sap") (sorted-map))]
         [netsuite (or (get entity "netsuite") (get defaults "netsuite") (sorted-map))]
         [sap (assoc sap "invoice_id" (or (get sap "invoice_id") (get entity "zoho_invoice_id") "INV-10001"))]
         [netsuite (assoc netsuite "invoice_id" (or (get netsuite "invoice_id") (get entity "zoho_invoice_id") "INV-10001"))]
         [netsuite (assoc netsuite "amount" (or (get netsuite "amount") (get entity "zoho_invoice_total") 2500.00))]
         [chain-flag (normalize-bool (or (get entity "chain_to_wf5") (get defaults "chain_to_wf5")) *wf4-chain-enabled*)])
    (sorted-map
      "claim_id"    claim-id
      "policy_id"   policy-id
      "sap"         sap
      "netsuite"    netsuite
      "chain_to_wf5" chain-flag)))

(defun wf4-build-wf5-inputs (entity parsed)
  (wf4-derive-wf5-inputs entity parsed))

(defun wf2-should-chain? (entity)
  "Determine whether WF2 should hand off to WF3 for the given entity."
  (normalize-bool (get entity "chain_to_wf3") *wf2-chain-enabled*))

(defun wf2-derive-wf3-inputs (entity parsed)
  "Build a payload for WF3 using WF2 entity data as a fallback. Returns nil for missing fields to allow defaults to be used in merge."
  (let* ([claim-id (get entity "claim_id")]
         [invoice-amount (or (get entity "invoice_amount")
                             (get entity "coverage_limit"))]
         [signer-name (or (get entity "signer_name")
                          (get entity "handler"))]
         [signer-email (get entity "signer_email")]
         [originator-name (get entity "originator_name")]
         [recipient-name (get entity "recipient_name")]
         [issue-date (get entity "issue_date")])
    (sorted-map
      "claim_id"        claim-id
      "policy_id"       (get entity "policy_id")
      "invoice_amount"  invoice-amount
      "signer_name"     signer-name
      "signer_email"    signer-email
      "originator_name" originator-name
      "recipient_name"  recipient-name
      "issue_date"      issue-date)))

(defun wf2-build-wf3-inputs (entity parsed)
  "Construct WF3 inputs, merging defaults with derived values from entity."
  (let* ([derived (wf2-derive-wf3-inputs entity parsed)]
         [defaults (or *wf2-wf3-default-inputs* (sorted-map))]
         [merged (sorted-map
                   "claim_id"        (or (get derived "claim_id") (get defaults "claim_id"))
                   "policy_id"       (or (get derived "policy_id") (get defaults "policy_id"))
                   "invoice_amount"  (or (get derived "invoice_amount") (get defaults "invoice_amount"))
                   "signer_name"     (or (get derived "signer_name") (get defaults "signer_name"))
                   "signer_email"    (or (get derived "signer_email") (get defaults "signer_email"))
                   "originator_name" (or (get derived "originator_name") (get defaults "originator_name"))
                   "recipient_name"  (or (get derived "recipient_name") (get defaults "recipient_name"))
                   "issue_date"      (or (get derived "issue_date") (get defaults "issue_date")))])
    ;; Validate critical fields after merge
    (when (nil? (get merged "claim_id"))
      (set-exception-business "missing claim_id for WF3 handoff (not in entity or defaults)"))
    (when (nil? (get merged "signer_name"))
      (set-exception-business "missing signer_name for WF3 handoff (not in entity or defaults)"))
    (when (nil? (get merged "signer_email"))
      (set-exception-business "missing signer_email for WF3 handoff (not in entity or defaults)"))
    (when (nil? (get merged "invoice_amount"))
      (set-exception-business "missing invoice_amount for WF3 handoff (not in entity or defaults)"))
    merged))

(defun set-wf1-chain-enabled! (flag)
  "Update the global WF1 chaining toggle at runtime."
  (set '*wf1-chain-enabled* (normalize-bool flag *wf1-chain-enabled*)))

(defun set-wf4-chain-enabled! (flag)
  "Update the global WF4 chaining toggle at runtime."
  (set '*wf4-chain-enabled* (normalize-bool flag *wf4-chain-enabled*)))

(defun set-wf3-chain-enabled! (flag)
  "Update the global WF3 chaining toggle at runtime."
  (set '*wf3-chain-enabled* (normalize-bool flag *wf3-chain-enabled*)))

(defun set-wf2-chain-enabled! (flag)
  "Update the global WF2 chaining toggle at runtime."
  (set '*wf2-chain-enabled* (normalize-bool flag *wf2-chain-enabled*)))

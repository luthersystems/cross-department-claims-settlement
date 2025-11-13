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

;; Chaining defaults: fallback values when WF1 chains to WF2
;; References workflow constants where appropriate to avoid duplication
(set '*wf1-wf2-default-inputs*
     (sorted-map
       "policy_id"        "POL-1001"
       "gw_claim_id"      "GW-1001"
       "signer_email"     "approver@example.com"
       "signer_name"      "Workflow Approver"
       "invoice_amount"   "25000.00"
       "originator_name"  *wf3-default-originator-name*  ; Reuse from WF3 constants
       "recipient_name"   *wf3-default-recipient-name*   ; Reuse from WF3 constants
       "issue_date"       *wf3-default-issue-date*       ; Reuse from WF3 constants
       "chain_to_wf3"     true))

;; -----------------------------------------------------------------------------
;; WF2 → WF3 chaining (Guidewire/MySQL/SP -> Invoice/Email)
;; -----------------------------------------------------------------------------
(set '*wf2-chain-enabled* true)

;; Optional default payload for invoking WF3 when chaining is enabled.
;; Set to () if you prefer to derive values dynamically from the WF2 entity.
;; Chaining defaults: fallback values when WF2 chains to WF3
;; References workflow constants where appropriate to avoid duplication
(set '*wf2-wf3-default-inputs*
     (sorted-map
       "claim_id"        "CLM-4567"
       "invoice_amount"  "20000.00"
       "signer_name"     "Jack Clarke"
       "signer_email"    *wf3-default-email-to*          ; Reuse from WF3 constants
       "originator_name" *wf3-default-originator-name*    ; Reuse from WF3 constants
       "recipient_name"  *wf3-default-recipient-name*     ; Reuse from WF3 constants
       "issue_date"      *wf3-default-issue-date*))       ; Reuse from WF3 constants

;; -----------------------------------------------------------------------------
;; WF3 → WF4 chaining (Invoice/Email -> Zoho/SharePoint/ServiceNow)
;; -----------------------------------------------------------------------------
(set '*wf3-chain-enabled* true)

;; Chaining defaults: fallback values when WF3 chains to WF4
;; References workflow constants where appropriate to avoid duplication
(set '*wf3-wf4-default-inputs*
     (sorted-map
       "zoho" (sorted-map
                 "customer_id"      *wf4-default-customer-id*
                 "reference_number" "CLAIM-8472"
                 "due_date"         *wf4-default-due-date*
                 "is_inclusive_tax" *wf4-default-is-inclusive-tax*
                 "currency_code"    *wf4-default-currency-code*
                 "line_items"       *wf4-default-line-items*)
       "sharepoint" (sorted-map
                      "site_id"  *wf4-default-sharepoint-site-id*
                      "drive_id" *wf4-default-sharepoint-drive-id*
                      "item_id"  *wf4-default-sharepoint-item-id*
                      "filename" *wf4-default-sharepoint-filename*)
       "servicenow" (sorted-map
                      "short_description" "Create ServiceNow incident for settlement invoice"
                      "description"      *wf4-default-servicenow-description*
                      "priority"         *wf4-default-servicenow-priority*
                      "category"         *wf4-default-servicenow-category*
                      "impact"           *wf4-default-servicenow-impact*
                      "urgency"          *wf4-default-servicenow-urgency*
                      "assignment_group" *wf4-default-servicenow-assignment-group*)
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
         [zoho (assoc zoho "customer_id"      (or (get zoho-base "customer_id") *wf4-default-customer-id*))]
         [zoho (assoc zoho "reference_number" (or (get zoho-base "reference_number") claim-id))]
         [zoho (assoc zoho "due_date"         (or (get zoho-base "due_date") *wf4-default-due-date*))]
         [zoho (assoc zoho "is_inclusive_tax" (normalize-bool (get zoho-base "is_inclusive_tax") *wf4-default-is-inclusive-tax*))]
         [zoho (assoc zoho "currency_code"    (or (get zoho-base "currency_code") *wf4-default-currency-code*))]
         [zoho (assoc zoho "line_items"       line-items)]
         [sharepoint (sorted-map)]
         [sharepoint (assoc sharepoint "site_id" (or (get sharepoint-base "site_id")
                                                    *wf4-default-sharepoint-site-id*))]
         [sharepoint (assoc sharepoint "drive_id" (or (get sharepoint-base "drive_id")
                                                     *wf4-default-sharepoint-drive-id*))]
         [sharepoint (assoc sharepoint "item_id" (or (get sharepoint-base "item_id")
                                                    *wf4-default-sharepoint-item-id*))]
         [sharepoint (assoc sharepoint "filename" (or (get sharepoint-base "filename")
                                                     *wf4-default-sharepoint-filename*))]
         [servicenow (sorted-map)]
         [servicenow (assoc servicenow "short_description" (or (get servicenow-base "short_description")
                                                               (format-string "Create incident for claim {}" claim-id)))]
         [servicenow (assoc servicenow "description"      (or (get servicenow-base "description")
                                                               *wf4-default-servicenow-description*))]
         [servicenow (assoc servicenow "priority"         (or (get servicenow-base "priority") *wf4-default-servicenow-priority*))]
         [servicenow (assoc servicenow "category"         (or (get servicenow-base "category") *wf4-default-servicenow-category*))]
         [servicenow (assoc servicenow "impact"           (or (get servicenow-base "impact") *wf4-default-servicenow-impact*))]
         [servicenow (assoc servicenow "urgency"          (or (get servicenow-base "urgency") *wf4-default-servicenow-urgency*))]
         [servicenow (assoc servicenow "assignment_group" (or (get servicenow-base "assignment_group") *wf4-default-servicenow-assignment-group*))]
         [servicenow (if (get servicenow-base "caller_id")
                         (assoc servicenow "caller_id" (get servicenow-base "caller_id"))
                         servicenow)]
         [chain-flag (normalize-bool (get defaults "chain_to_wf4") true)])
    (sorted-map
      "claim_id"    claim-id
      "policy_id"   (or (get entity "policy_id") *wf4-default-policy-id*)
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

;; Chaining defaults: fallback values when WF4 chains to WF5
;; References workflow constants where appropriate to avoid duplication
(set '*wf4-wf5-default-inputs*
     (sorted-map
       "claim_id" "CLM-4567"
       "policy_id" *wf4-default-policy-id*  ; Reuse from WF4 constants
       "sap" (sorted-map
                "payment_id"     "PAYM-1001"  ; Different from WF5 default (chaining-specific)
                "invoice_id"     "INV-10001"  ; Different from WF5 default (chaining-specific)
                "reference"      "Batch-Nov-02"
                "vendor_id"      *wf5-default-sap-vendor-id*
                "amount"         *wf5-default-sap-amount*
                "currency"       *wf5-default-sap-currency*
                "payment_method" *wf5-default-sap-payment-method*
                "payment_date"   "2025-11-07"
                "status"         *wf5-default-sap-status*)
       "netsuite" (sorted-map
                    "invoice_id" "INV-10001"
                    "amount"     *wf5-default-sap-amount*
                    "currency"   *wf5-default-sap-currency*
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

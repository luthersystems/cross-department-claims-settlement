(in-package 'sandbox)

(use-package 'connector)

;; -----------------------------------------------------------------------------
;; Constants for WF4
;; -----------------------------------------------------------------------------

(set '*wf4-default-customer-id* "7533684000000109011")
(set '*wf4-default-currency-code* "GBP")
(set '*wf4-default-is-inclusive-tax* true)
(set '*wf4-default-line-items* (vector (sorted-map
                                         "name"     "Inter-Entity Settlement"
                                         "rate"     1250.0
                                         "quantity" 1)))
(set '*wf4-default-policy-id* "POL-8872")
(set '*wf4-default-sharepoint-site-id* "samwoodluthersystems.sharepoint.com,af554837-6d2d-48e7-aa08-9584e15df76e,28227d76-23e6-4218-85c5-0473c0006245")
(set '*wf4-default-sharepoint-drive-id* "b!N0hVry1t50iqCJWE4V33bnZ9IijmIxhChcUEc8AAYkU0cfiPk4MZRaBijb338Qw8")
(set '*wf4-default-sharepoint-item-id* "01RAAXWAZH6LCSA5FLHRE2QJXBSIVDOGV4")
(set '*wf4-default-sharepoint-filename* "id-verification.txt")
(set '*wf4-default-servicenow-priority* "3")
(set '*wf4-default-servicenow-category* "Finance")
(set '*wf4-default-servicenow-impact* "2")
(set '*wf4-default-servicenow-urgency* "2")
(set '*wf4-default-servicenow-assignment-group* "Finance Ops")
(set '*wf4-default-servicenow-description* "Auto-generated incident for inter-entity settlement review")

;; Build input parameters for WF4 from a request map
;; Supports direct route invocation or chained workflow handoffs.
;; Minimal required fields: customer_id, reference_number, due_date, is_inclusive_tax, line_items
(defun build-wf4-inputs (req)
  (let* ([zoho-raw       (or (get req "zoho") (sorted-map))]
         [sharepoint-raw (or (get req "sharepoint") (sorted-map))]
         [servicenow-raw (or (get req "servicenow") (sorted-map))]
         ;; Extract claim_id from reference_number if not provided
         [claim-id (or (get req "claim_id")
                       (get req "reference_number")
                       (get zoho-raw "reference_number")
                       (set-exception-business "missing claim_id or reference_number"))]
         [policy-id (or (get req "policy_id") *wf4-default-policy-id*)]
         [chain-to-wf5 (normalize-bool (or (get req "chain_to_wf5")
                                           (get sharepoint-raw "chain_to_wf5")) *wf4-chain-enabled*)]
         ;; Zoho fields - prioritize direct request fields, then zoho nested, then defaults
         [customer-id      (or (get req "customer_id")
                               (get zoho-raw "customer_id")
                               *wf4-default-customer-id*)]
         [reference-number (or (get req "reference_number")
                               (get zoho-raw "reference_number")
                               claim-id)]
         [due-date         (or (get req "due_date")
                               (get zoho-raw "due_date")
                               (format-date (now) "%Y-%m-%d"))]
         [currency-code    (or (get req "currency_code")
                               (get zoho-raw "currency_code")
                               *wf4-default-currency-code*)]
         [inclusive-tax    (normalize-bool (or (get req "is_inclusive_tax")
                                               (get zoho-raw "is_inclusive_tax")
                                               *wf4-default-is-inclusive-tax*))]
         [line-items-raw   (or (get req "line_items")
                                (get zoho-raw "line_items"))]
         [line-items       (cond
                             ((vector? line-items-raw) line-items-raw)
                             ((nil? line-items-raw) *wf4-default-line-items*)
                             (:else (vector line-items-raw)))]
         [zoho (sorted-map
                 "customer_id"      customer-id
                 "reference_number" reference-number
                 "due_date"         due-date
                 "is_inclusive_tax" inclusive-tax
                 "currency_code"    currency-code
                 "line_items"       line-items)]
         ;; SharePoint - use defaults
         [sharepoint (sorted-map
                       "site_id"  (or (get sharepoint-raw "site_id")
                                      (get req "site_id")
                                      *wf4-default-sharepoint-site-id*)
                       "drive_id" (or (get sharepoint-raw "drive_id")
                                      (get req "drive_id")
                                      *wf4-default-sharepoint-drive-id*)
                       "item_id"  (or (get sharepoint-raw "item_id")
                                      (get req "item_id")
                                      *wf4-default-sharepoint-item-id*)
                       "filename" (or (get sharepoint-raw "filename")
                                      (get req "filename")
                                      *wf4-default-sharepoint-filename*))]
         ;; ServiceNow - use defaults
         [servicenow (sorted-map
                       "short_description" (or (get servicenow-raw "short_description")
                                                (get req "short_description")
                                                (format-string "Create incident for claim {}" claim-id))
                       "description"      (or (get servicenow-raw "description")
                                              (get req "description")
                                              *wf4-default-servicenow-description*)
                       "priority"         (or (get servicenow-raw "priority")
                                              (get req "priority")
                                              *wf4-default-servicenow-priority*)
                       "category"         (or (get servicenow-raw "category")
                                              (get req "category")
                                              *wf4-default-servicenow-category*)
                       "impact"           (or (get servicenow-raw "impact")
                                              (get req "impact")
                                              *wf4-default-servicenow-impact*)
                       "urgency"          (or (get servicenow-raw "urgency")
                                              (get req "urgency")
                                              *wf4-default-servicenow-urgency*)
                       "assignment_group" (or (get servicenow-raw "assignment_group")
                                              (get req "assignment_group")
                                              *wf4-default-servicenow-assignment-group*)
                       "caller_id"        (or (get servicenow-raw "caller_id")
                                              (get req "caller_id")))])
    (sorted-map
      "claim_id"   claim-id
      "policy_id"  policy-id
      "zoho"       zoho
      "sharepoint" sharepoint
      "servicenow" servicenow
      "chain_to_wf5" chain-to-wf5)))

(defendpoint "upload_claim_wf4" (req)
  (cc:infof (sorted-map "req" req) "upload_claim_wf4 called")
  (let* ([inputs (build-wf4-inputs req)]
         [result (invoke-workflow claim-manager-wf4 inputs)])
    (cc:infof (sorted-map "result" result) "upload_claim_wf4 completed")
    (route-success (sorted-map "claim_id" (get result "claim_id")))))

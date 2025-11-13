(in-package 'cdcs)



;; Note: Constants moved to 04-constants.lisp

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
         ;; Zoho fields - prioritize direct request fields, then zoho nested, then defaults
         [customer-id      (or (get req "customer_id")
                               (get zoho-raw "customer_id")
                               *wf4-default-customer-id*)]
         [reference-number (or (get req "reference_number")
                               (get zoho-raw "reference_number")
                               claim-id)]
         [due-date         (or (get req "due_date")
                               (get zoho-raw "due_date")
                               *wf4-default-due-date*)]
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
      "servicenow" servicenow)))

(defendpoint "upload_claim_wf4" (req)
  (let* ([inputs (build-wf4-inputs req)]
         [result (invoke-workflow claim-manager-wf4 inputs)])
    (route-success (sorted-map "claim_id" (get result "claim_id")))))

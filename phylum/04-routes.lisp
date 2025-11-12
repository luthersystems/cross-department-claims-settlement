(in-package 'sandbox)

(use-package 'connector)

;; Build input parameters for WF4 from a request map
;; Supports direct route invocation or chained workflow handoffs.
(defun build-wf4-inputs (req)
  (let* ([zoho-raw       (or (get req "zoho") (sorted-map))]
         [sharepoint-raw (or (get req "sharepoint") (sorted-map))]
         [servicenow-raw (or (get req "servicenow") (sorted-map))]
         [claim-id (or (get req "claim_id")
                       (get zoho-raw "reference_number")
                       (set-exception-business "missing claim_id"))]
         [policy-id (or (get req "policy_id") "POL-8872")]
         [chain-to-wf5 (normalize-bool (or (get req "chain_to_wf5")
                                           (get sharepoint-raw "chain_to_wf5")) *wf4-chain-enabled*)]
         [customer-id      (or (get zoho-raw "customer_id")      (get req "customer_id")      "1234567000001")]
         [reference-number (or (get zoho-raw "reference_number") (get req "reference_number") claim-id)]
         [due-date         (or (get zoho-raw "due_date")         (get req "due_date")         (format-date (now) "%Y-%m-%d"))]
         [currency-code    (or (get zoho-raw "currency_code")    (get req "currency_code")    "GBP")]
         [inclusive-tax    (normalize-bool (or (get zoho-raw "is_inclusive_tax")
                                              (get req "is_inclusive_tax")) true)]
         [line-items-raw   (or (get zoho-raw "line_items") (get req "line_items"))]
         [line-items       (cond
                             ((vector? line-items-raw) line-items-raw)
                             ((nil? line-items-raw)
                              (vector (sorted-map
                                        "name"     "Inter-Entity Settlement"
                                        "rate"     1250.0
                                        "quantity" 1)))
                             (:else (vector line-items-raw)))]
         [zoho (sorted-map
                 "customer_id"      customer-id
                 "reference_number" reference-number
                 "due_date"         due-date
                 "is_inclusive_tax" inclusive-tax
                 "currency_code"    currency-code
                 "line_items"       line-items)]
         [sharepoint (sorted-map
                       "site_id"  (or (get sharepoint-raw "site_id")  (get req "site_id")
                                       "samwoodluthersystems.sharepoint.com,af554837-6d2d-48e7-aa08-9584e15df76e,28227d76-23e6-4218-85c5-0473c0006245")
                       "drive_id" (or (get sharepoint-raw "drive_id") (get req "drive_id")
                                       "b!N0hVry1t50iqCJWE4V33bnZ9IijmIxhChcUEc8AAYkU0cfiPk4MZRaBijb338Qw8")
                       "item_id"  (or (get sharepoint-raw "item_id")  (get req "item_id")
                                       "01RAAXWAZH6LCSA5FLHRE2QJXBSIVDOGV4")
                       "filename" (or (get sharepoint-raw "filename") (get req "filename")
                                       "id-verification.txt"))]
         [servicenow (sorted-map
                       "short_description" (or (get servicenow-raw "short_description")
                                                (get req "short_description")
                                                (format-string "Create incident for claim {}" claim-id))
                       "description"      (or (get servicenow-raw "description")
                                                (get req "description")
                                                "Auto-generated incident for inter-entity settlement review")
                       "priority"         (or (get servicenow-raw "priority")         (get req "priority")         "3")
                       "category"         (or (get servicenow-raw "category")         (get req "category")         "Finance")
                       "impact"           (or (get servicenow-raw "impact")           (get req "impact")           "2")
                       "urgency"          (or (get servicenow-raw "urgency")          (get req "urgency")          "2")
                       "assignment_group" (or (get servicenow-raw "assignment_group") (get req "assignment_group") "Finance Ops")
                       "caller_id"        (or (get servicenow-raw "caller_id")        (get req "caller_id")))])
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

(in-package 'sandbox)

;; -----------------------------------------------------------------------------
;; Constants for Workflow 4 (Zoho/SharePoint/ServiceNow)
;; -----------------------------------------------------------------------------

;; Default policy ID
(set '*wf4-default-policy-id* "POL-8872")

;; Zoho defaults
(set '*wf4-default-customer-id* "7533684000000109011")
(set '*wf4-default-currency-code* "GBP")
(set '*wf4-default-is-inclusive-tax* true)
(set '*wf4-default-line-items* (vector (sorted-map
                                         "name"     "Inter-Entity Settlement"
                                         "rate"     1250.0
                                         "quantity" 1)))
(set '*wf4-default-due-date* "2025-11-12")

;; SharePoint defaults
(set '*wf4-default-sharepoint-site-id* "samwoodluthersystems.sharepoint.com,af554837-6d2d-48e7-aa08-9584e15df76e,28227d76-23e6-4218-85c5-0473c0006245")
(set '*wf4-default-sharepoint-drive-id* "b!N0hVry1t50iqCJWE4V33bnZ9IijmIxhChcUEc8AAYkU0cfiPk4MZRaBijb338Qw8")
(set '*wf4-default-sharepoint-item-id* "01RAAXWAZH6LCSA5FLHRE2QJXBSIVDOGV4")
(set '*wf4-default-sharepoint-filename* "id-verification.txt")

;; ServiceNow defaults
(set '*wf4-default-servicenow-priority* "3")
(set '*wf4-default-servicenow-category* "Finance")
(set '*wf4-default-servicenow-impact* "2")
(set '*wf4-default-servicenow-urgency* "2")
(set '*wf4-default-servicenow-assignment-group* "Finance Ops")
(set '*wf4-default-servicenow-description* "Auto-generated incident for inter-entity settlement review")


(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; Connector IDs - Derived from connectorhub.yaml connector names
;; IDs are lowercase with spaces and underscores replaced by hyphens
;; These match the pod/container naming convention: mcp-{connector-id}
;; -----------------------------------------------------------------------------

;; Workflow 1 connectors
(set '*connector-id-oracle* "oracle")
(set '*connector-id-equifax* "equifax")
(set '*connector-id-teams* "teams")

;; Workflow 2 connectors
(set '*connector-id-outboundgw* "outboundgw")
(set '*connector-id-mysql* "mysql")
(set '*connector-id-sharepoint* "sharepoint")

;; Workflow 3 connectors
(set '*connector-id-esignature* "esignature")  
(set '*connector-id-salesforce* "salesforce")
(set '*connector-id-email* "email")

;; Workflow 4 connectors
(set '*connector-id-zoho* "zoho")
(set '*connector-id-servicenow* "servicenow")

;; Workflow 5 connectors
(set '*connector-id-absinbound* "absinbound")
(set '*connector-id-contractsigned* "contractsigned")
(set '*connector-id-paymentsigned* "paymentsigned")
(set '*connector-id-sap* "sap")
(set '*connector-id-d365fo* "d365fo")

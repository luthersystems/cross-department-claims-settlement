(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; Constants for Workflow 5 (SAP/NetSuite)
;; -----------------------------------------------------------------------------

;; SAP payment defaults
(set '*wf5-default-sap-payment-id* "PAYM-002")
(set '*wf5-default-sap-invoice-id* "INV-1002")
(set '*wf5-default-sap-reference* "Batch-Nov-01")
(set '*wf5-default-sap-vendor-id* "VEND-001")
(set '*wf5-default-sap-amount* 2500.00)
(set '*wf5-default-sap-currency* "USD")
(set '*wf5-default-sap-payment-method* "EFT")
(set '*wf5-default-sap-payment-date* "2025-11-06")
(set '*wf5-default-sap-status* "PENDING")

;; SAP parse defaults (fallback values)
(set '*wf5-default-sap-transaction-id* "SAP-TXN-1001")
(set '*wf5-default-sap-posting-ref* "SAP-POST-REF")
(set '*wf5-default-sap-posted-status* "posted")


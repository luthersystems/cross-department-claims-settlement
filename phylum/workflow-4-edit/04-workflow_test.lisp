;; Copyright © 2025 Luther Systems, Ltd. All right reserved.
;; Unit tests for Workflow 4: Zoho Invoice Creation

(in-package 'cdcs)
(use-package 'testing)

;; Test helper: Create a test entity
(defun mk-test-entity-wf4 ()
  (sorted-map
   "claim_id" "CLM-4567"
   "policy_id" "POL-8872"
   "customer_id" "CUST-12345"
   "reference_number" "CLM-4567"))

;; Test helper: Create mock Zoho response
(defun mk-test-zoho-response ()
  (sorted-map
   "request_id" "req-zoho-123"
   "response" (sorted-map
                "generic" (sorted-map
                           "text" "{\"invoice\":{\"invoice_id\":\"INV-789\",\"invoice_number\":\"INV-001\",\"customer_id\":\"CUST-12345\",\"customer_name\":\"Test Customer\",\"status\":\"sent\",\"date\":\"2024-01-15\",\"due_date\":\"2024-02-15\",\"reference_number\":\"CLM-4567\",\"total\":2500.00,\"balance\":2500.00,\"url\":\"https://zoho.com/invoice/789\"}}"))))

;; Test helper: Create mock SharePoint response
(defun mk-test-sharepoint-response ()
  (sorted-map
   "request_id" "req-sp-123"
   "response" (sorted-map
                "generic" (sorted-map
                           "text" "{\"item\":{\"id\":\"sp-item-123\",\"name\":\"invoice.pdf\",\"webUrl\":\"https://sharepoint.com/item\",\"@microsoft.graph.downloadUrl\":\"https://sharepoint.com/download\"}}"))))

;; Test helper: Create mock ServiceNow response
(defun mk-test-servicenow-response ()
  (sorted-map
   "request_id" "req-sn-123"
   "response" (sorted-map
                "generic" (sorted-map
                           "text" "{\"result\":{\"sys_id\":\"INC-12345\",\"number\":\"INC0012345\",\"state\":\"2\"}}"))))

;; =============================
;; Test: Parse Zoho Invoice Response
;; =============================
(test "parse-zoho-create-invoice"
      (let* ([resp (mk-test-zoho-response)]
             [parsed (parse-zoho-create-invoice resp)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "invoice_id") "INV-789"))
        (assert (equal? (get parsed "invoice_number") "INV-001"))
        (assert (equal? (get parsed "customer_id") "CUST-12345"))
        (assert (= (get parsed "total") 2500.00))))

;; =============================
;; Test: Parse SharePoint Response
;; =============================
(test "wf4-parse-sharepoint-docs"
      (let* ([resp (mk-test-sharepoint-response)]
             [parsed (wf4-parse-sharepoint-docs resp)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "item_id") "sp-item-123"))
        (assert (equal? (get parsed "name") "invoice.pdf"))
        (assert (not (nil? (get parsed "web_url"))))))

;; =============================
;; Test: Parse ServiceNow Response
;; =============================
(test "parse-servicenow-create-incident"
      (let* ([resp (mk-test-servicenow-response)]
             [parsed (parse-servicenow-create-incident resp)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "incident_id") "INC-12345"))
        (assert (equal? (get parsed "incident_number") "INC0012345"))
        (assert (equal? (get parsed "state") "2"))))

;; =============================
;; Test: Create Zoho Event
;; =============================
(test "mk-zoho-create-invoice-event"
      (let* ([entity (mk-test-entity-wf4)]
             [payload (sorted-map
                       "customer_id" "CUST-12345"
                       "reference_number" "CLM-4567"
                       "due_date" "2024-02-15"
                       "is_inclusive_tax" true
                       "line_items" (vector
                                      (sorted-map
                                       "name" "Claim Settlement"
                                       "rate" 2500.00
                                       "quantity" 1)))]
             [event (mk-zoho-create-invoice-event entity payload)])
        (assert (not (nil? event)))
        (assert (equal? (get event "oid") "CLM-4567"))
        (assert (equal? (get event "sys") "zoho"))
        (assert (equal? (get event "eng") "create invoice"))))

;; =============================
;; Test: Create ServiceNow Event
;; =============================
(test "mk-servicenow-create-incident-event"
      (let* ([entity (mk-test-entity-wf4)]
             [payload (sorted-map
                       "short_description" "Invoice created for claim CLM-4567"
                       "description" "Zoho invoice INV-789 created"
                       "category" "Invoice"
                       "subcategory" "Settlement")]
             [event (mk-servicenow-create-incident-event entity payload)])
        (assert (not (nil? event)))
        (assert (equal? (get event "oid") "CLM-4567"))
        (assert (equal? (get event "sys") "servicenow"))
        (assert (equal? (get event "eng") "create incident"))))

;; =============================
;; Test: Init State Handler Parse
;; =============================
(test "wf4-claim-init-state-handler-parse"
      (let* ([handler (wf4-claim-init-simple-state-handler)]
             [parse-fn (get handler :parse)]
             [resp (sorted-map
                    "policy_id" "POL-8872"
                    "zoho" (sorted-map
                            "customer_id" "CUST-12345"
                            "reference_number" "CLM-4567"
                            "due_date" "2024-02-15"
                            "is_inclusive_tax" true
                            "line_items" (vector
                                           (sorted-map
                                            "name" "Claim Settlement"
                                            "rate" 2500.00
                                            "quantity" 1))))]
             [entity (sorted-map "claim_id" "CLM-4567")]
             [parsed (funcall parse-fn resp entity)])
        (assert (not (nil? parsed)))
        ;; Init handler validates claim_id exists but doesn't include it in parsed
        ;; claim_id is managed by entity manager, not persisted in stage functions
        (assert (nil? (get parsed "claim_id")))
        (assert (equal? (length (keys parsed)) 0))))

;; =============================
;; Test: Zoho Invoice Created State Handler
;; =============================
(test "wf4-zoho-invoice-created-state-handler"
      (let* ([handler (wf4-zoho-invoice-created-state-handler)]
             [parse-fn (get handler :parse)]
             [stage-durable-fn (get handler :stage-durable)]
             [resp (mk-test-zoho-response)]
             [entity (mk-test-entity-wf4)]
             [parsed (parse-fn resp entity)]
             [durable (stage-durable-fn entity parsed (sorted-map))])
        (assert (not (nil? parsed)))
        (assert (not (nil? durable)))
        (assert (equal? (get durable "zoho_invoice_id") "INV-789"))
        (assert (equal? (get durable "zoho_invoice_number") "INV-001"))))


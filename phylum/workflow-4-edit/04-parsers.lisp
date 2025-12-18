(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; Parsers and Event Creators for Workflow 4 (Zoho → SharePoint → ServiceNow)
;; -----------------------------------------------------------------------------

(defun mk-zoho-create-invoice-event (entity payload accessors)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind" "KIND_ZOHO_BOOKS"
                  "operation" "create_invoice"
                  "args" (sorted-map "json_data" payload)))])
    (build-event entity req "create invoice" "ZOHO" (get accessors :entity-id))))

(defun parse-zoho-create-invoice (resp)
  (let* ([parsed (parse-generic-resp resp)]
         [invoice (or (get parsed "invoice")
                      (set-exception-business "Zoho response missing invoice"))])
    (sorted-map
      "invoice_id"      (get invoice "invoice_id")
      "invoice_number"  (get invoice "invoice_number")
      "customer_id"     (get invoice "customer_id")
      "customer_name"   (get invoice "customer_name")
      "status"          (get invoice "status")
      "date"            (get invoice "date")
      "due_date"        (get invoice "due_date")
      "reference_number"(get invoice "reference_number")
      "total"           (get invoice "total")
      "balance"         (get invoice "balance")
      "url"             (or (get invoice "url") (get invoice "invoice_url"))
      "line_items"      (get invoice "line_items"))))

(defun wf4-mk-sharepoint-get-id-doc-event (entity args accessors)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind" "KIND_MICROSOFT_SHAREPOINT"
                  "operation" "get_document_content"
                  "args" args))])
    (build-event entity req "get sharepoint doc" "SHAREPOINT" (get accessors :entity-id))))

(defun wf4-parse-sharepoint-docs (resp)
  (let* ([parsed (parse-generic-resp resp)]
         [item (or (get parsed "item") parsed)])
    (sorted-map
      "item_id"    (get item "id")
      "name"       (get item "name")
      "web_url"    (get item "webUrl")
      "download_url" (get item "@microsoft.graph.downloadUrl"))))

(defun mk-servicenow-create-incident-event (entity payload accessors)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind" "KIND_SERVICENOW"
                  "operation" "create_incident"
                  "args" payload))])
    (build-event entity req "create incident" "SERVICENOW" (get accessors :entity-id))))

(defun parse-servicenow-create-incident (resp)
  (let* ([parsed (parse-generic-resp resp)]
         [result (or (get parsed "result") parsed)])
    (sorted-map
      "incident_id"     (or (get result "incident_id") (get result "sys_id"))
      "incident_number" (or (get result "incident_number") (get result "number"))
      "state"           (get result "state")
      "short_description" (get result "short_description")
      "url"             (get result "link"))))

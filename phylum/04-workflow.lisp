(in-package 'sandbox)

;; -----------------------------------------------------------------------------
;; Helper functions for Workflow 4 (Zoho → SharePoint → ServiceNow)
;; -----------------------------------------------------------------------------

(defun mk-zoho-create-invoice-event (entity payload)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind" "KIND_ZOHO_BOOKS"
                  "operation" "create_invoice"
                  "args" (sorted-map "json_data" payload)))])
    (build-event entity req "create invoice" "ZOHO")))

(defun parse-zoho-create-invoice (resp)
  (let* ([parsed (parse-generic-resp resp)]
         [invoice (or (get parsed "invoice")
                      (set-exception-business "Zoho response missing invoice"))])
    (cc:infof (sorted-map "parsed" parsed "invoice" invoice) "parsing Zoho invoice response")
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

(defun mk-servicenow-create-incident-event (entity payload)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind" "KIND_SERVICENOW"
                  "operation" "create_incident"
                  "args" payload))])
    (build-event entity req "create incident" "SERVICENOW")))

(defun parse-servicenow-create-incident (resp)
  (let* ([parsed (parse-generic-resp resp)]
         [result (or (get parsed "result") parsed)])
    (sorted-map
      "incident_id"     (or (get result "incident_id") (get result "sys_id"))
      "incident_number" (or (get result "incident_number") (get result "number"))
      "state"           (get result "state")
      "short_description" (get result "short_description")
      "url"             (get result "link"))))

;; -----------------------------------------------------------------------------
;; State handlers
;; -----------------------------------------------------------------------------

(defun wf4-claim-init-state-handler ()
  (labels
    ([parse (resp entity)
      (let* ([zoho       (or (get resp "zoho") (set-exception-business "missing zoho payload"))]
             [sharepoint (or (get resp "sharepoint") (set-exception-business "missing sharepoint payload"))]
             [servicenow (or (get resp "servicenow") (set-exception-business "missing servicenow payload"))]
             [claim-id   (or (get resp "claim_id") (get entity "claim_id"))]
             [policy-id  (or (get resp "policy_id") (get entity "policy_id") *wf4-default-policy-id*)])
        (when (nil? claim-id)
          (set-exception-business "missing claim_id"))
        (sorted-map
          "claim_id"   claim-id
          "policy_id"  policy-id
          "zoho"       zoho
          "sharepoint" sharepoint
          "servicenow" servicenow))]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "claim_id"   (get parsed "claim_id")
        "policy_id"  (get parsed "policy_id")
        "zoho"       (get parsed "zoho")
        "sharepoint" (get parsed "sharepoint")
        "servicenow" (get parsed "servicenow"))]
     [create-events (entity parsed accessors)
      (vector (mk-zoho-create-invoice-event entity (get parsed "zoho")))])
    (mk-state-handler
      :next            "WF4_CLAIM_STATE_ZOHO_INVOICE_CREATED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf4-zoho-invoice-created-state-handler ()
  (labels
    ([parse (resp entity) (parse-zoho-create-invoice resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "zoho_invoice_id"      (get parsed "invoice_id")
        "zoho_invoice_number"  (get parsed "invoice_number")
        "zoho_invoice_status"  (get parsed "status")
        "zoho_invoice_url"     (get parsed "url")
        "zoho_invoice_total"   (get parsed "total")
        "zoho_invoice_balance" (get parsed "balance")
        "zoho_customer_id"     (get parsed "customer_id")
        "zoho_customer_name"   (get parsed "customer_name"))]
     [create-events (entity parsed accessors)
      (vector (mk-sharepoint-get-id-doc-event entity (get entity "sharepoint")))])
    (mk-state-handler
      :next            "WF4_CLAIM_STATE_SHAREPOINT_DOC_RETRIEVED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf4-sharepoint-doc-retrieved-state-handler ()
  (labels
    ([parse (resp entity)
      (let* ([documents (parse-sharepoint-docs resp)])
        (assoc documents "retrieved_at" "2025-11-11"))]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map "sharepoint_documents" parsed)]
     [create-events (entity parsed accessors)
      (vector (mk-servicenow-create-incident-event entity (get entity "servicenow")))])
    (mk-state-handler
      :next            "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf4-servicenow-incident-created-state-handler ()
  (labels
    ([parse (resp entity) (parse-servicenow-create-incident resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "servicenow_incident_id"     (get parsed "incident_id")
        "servicenow_incident_number" (get parsed "incident_number")
        "servicenow_state"           (get parsed "state")
        "servicenow_url"             (get parsed "url")
        "servicenow_short_description" (get parsed "short_description"))]
     [create-events (entity parsed accessors) ()])
    (mk-state-handler
      :next            "WF4_CLAIM_STATE_DONE"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf4-claim-done-state-handler (&optional next-state)
  (labels
    ([parse (resp entity) (if (nil? resp) (sorted-map) (parse-generic-resp resp))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors) ()]
     [create-events (entity parsed accessors) ()])
    (mk-state-handler
      :next            (or next-state "WF4_CLAIM_STATE_DONE")
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events
      :immediate-next  (when next-state true))))
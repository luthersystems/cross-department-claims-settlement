(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; State handlers for Workflow 4 (Zoho → SharePoint → ServiceNow)
;; -----------------------------------------------------------------------------

(defun wf4-claim-init-state-handler ()
  (labels
    ([receive (resp entity accessors)
      ;; Prioritize resp (explicit request) over entity (accumulated data), then defaults
      ;; For unified process, resp is empty so falls back to entity
      (let* ([claim-id   (or (get resp "claim_id") (get entity "claim_id"))]
             [policy-id  (or (get resp "policy_id") (get entity "policy_id") *wf4-default-policy-id*)]
             ;; Hardcode defaults for now
             [zoho       (or (get resp *connector-id-zoho*)
                            (get entity *connector-id-zoho*)
                            (sorted-map
                              "customer_id"      *wf4-default-customer-id*
                              "reference_number" (or claim-id "WF4-CLAIM-001")
                              "due_date"         *wf4-default-due-date*
                              "is_inclusive_tax" *wf4-default-is-inclusive-tax*
                              "currency_code"    *wf4-default-currency-code*
                              "line_items"       *wf4-default-line-items*))]
             [sharepoint (or (get resp *connector-id-sharepoint*)
                            (get entity *connector-id-sharepoint*)
                            (sorted-map
                              "site_id"  *wf4-default-sharepoint-site-id*
                              "drive_id" *wf4-default-sharepoint-drive-id*
                              "item_id"  *wf4-default-sharepoint-item-id*
                              "filename" *wf4-default-sharepoint-filename*))]
             [servicenow (or (get resp *connector-id-servicenow*)
                            (get entity *connector-id-servicenow*)
                            (sorted-map
                              "short_description" (format-string "Create incident for claim {}" (or claim-id "WF4-CLAIM-001"))
                              "description"      *wf4-default-servicenow-description*
                              "priority"         *wf4-default-servicenow-priority*
                              "category"         *wf4-default-servicenow-category*
                              "impact"           *wf4-default-servicenow-impact*
                              "urgency"          *wf4-default-servicenow-urgency*
                              "assignment_group" *wf4-default-servicenow-assignment-group*))])
        ;; NEVER include claim_id in received - it's managed by entity manager
        (sorted-map
          "policy_id"  policy-id
          *connector-id-zoho*       zoho
          *connector-id-sharepoint* sharepoint
          *connector-id-servicenow* servicenow))]

     [validate (received entity accessors)
       (let* ([claim-id (or (get entity "claim_id"))])
         (when (nil? claim-id)
           (set-exception-business "missing claim_id"))
         received)]

     [decide-next-state (validated entity accessors)
       "WF4_CLAIM_STATE_ZOHO_INVOICE_CREATED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      ;; NEVER include claim_id in store-durable - it causes full entity replacement
      (sorted-map
        "policy_id"  (get validated "policy_id")
        *connector-id-zoho*       (get validated *connector-id-zoho*)
        *connector-id-sharepoint* (get validated *connector-id-sharepoint*)
        *connector-id-servicenow* (get validated *connector-id-servicenow*))]

     [send (entity validated accessors)
      (vector (mk-zoho-create-invoice-event entity (get validated *connector-id-zoho*) accessors))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

(defun wf4-zoho-invoice-created-state-handler ()
  (labels
    ([receive (resp entity accessors)
      (parse-zoho-create-invoice resp)]

     [validate (received entity accessors)
      (when (nil? (get received "invoice_id")) (set-exception-business "missing invoice_id"))
      received]

     [decide-next-state (validated entity accessors)
      "WF4_CLAIM_STATE_SHAREPOINT_DOC_RETRIEVED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map
        "zoho_invoice_id"      (get validated "invoice_id")
        "zoho_invoice_number"  (get validated "invoice_number")
        "zoho_invoice_status"  (get validated "status")
        "zoho_invoice_url"     (get validated "url")
        "zoho_invoice_total"   (get validated "total")
        "zoho_invoice_balance" (get validated "balance")
        "zoho_customer_id"     (get validated "customer_id")
        "zoho_customer_name"   (get validated "customer_name"))]

     [send (entity validated accessors)
      (vector (wf4-mk-sharepoint-get-id-doc-event entity (get entity *connector-id-sharepoint*) accessors))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

(defun wf4-sharepoint-doc-retrieved-state-handler ()
  (labels
    ([receive (resp entity accessors)
      (let* ([documents (wf4-parse-sharepoint-docs resp)])
        (assoc documents "retrieved_at" "2025-11-11"))]

     [validate (received entity accessors)
      (when (nil? (get received "documents")) (set-exception-business "missing documents in sharepoint response"))
      received]

     [decide-next-state (validated entity accessors)
      "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map "sharepoint_documents" validated)]

     [send (entity validated accessors)
      (vector (mk-servicenow-create-incident-event entity (get entity *connector-id-servicenow*) accessors))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

(defun wf4-servicenow-incident-created-state-handler (&optional next-state after-storage-hook)
  (labels
    ([receive (resp entity accessors)
      (parse-servicenow-create-incident resp)]

     [validate (received entity accessors)
      (when (nil? (get received "incident_id")) (set-exception-business "missing incident_id"))
      received]

     [decide-next-state (validated entity accessors)
      (or next-state "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED")]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map
        "servicenow_incident_id"     (get validated "incident_id")
        "servicenow_incident_number" (get validated "incident_number")
        "servicenow_state"           (get validated "state")
        "servicenow_url"             (get validated "url")
        "servicenow_short_description" (get validated "short_description"))]

     [send (entity validated accessors) (vector)])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send
      :after-storage-hook after-storage-hook)))
(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; State handlers for Workflow 4 (Zoho → SharePoint → ServiceNow)
;; -----------------------------------------------------------------------------

(defun wf4-claim-init-simple-state-handler ()
  (labels
    ([receive (resp entity accessors)
      (let* ([claim-id (or (get resp "claim_id") (get entity "claim_id"))])
        (sorted-map "claim_id" claim-id))]

     [validate (received entity accessors)
       (when (nil? (get received "claim_id")) (set-exception-business "missing claim_id"))
       received]

     [decide-next-state (validated entity accessors)
       "WF4_CLAIM_STATE_WAITING_FOR_SIGNATURE"]

     [store-ephemeral (entity validated accessors) (vector)]
     [store-durable (entity validated accessors) (sorted-map)]
     [send (entity validated accessors) (vector)])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

(defun wf4-claim-waiting-for-signature-state-handler ()
  (labels
    ([receive (resp entity accessors)
      (let* ([claim-id    (or (get resp "claim_id") (get entity "claim_id"))]
             [signed-by   (get resp "signedBy")]
             [verified-by (or (get resp "verifiedBy") "jack.clarke@luthersystems.com")]
             [zoho       (or (get resp *connector-id-zoho*)
                          (get entity *connector-id-zoho*)
                          (sorted-map
                            "customer_id"      *wf4-default-customer-id*
                            "reference_number" (or claim-id "WF4-CLAIM-001")
                            "due_date"         *wf4-default-due-date*
                            "is_inclusive_tax" *wf4-default-is-inclusive-tax*
                            "currency_code"    *wf4-default-currency-code*
                            "line_items"       *wf4-default-line-items*))])
        (sorted-map
          "signed_by"   signed-by
          "verified_by" verified-by
          *connector-id-zoho*        zoho))]

     [validate (received entity accessors)
       received]

     [decide-next-state (validated entity accessors)
       "WF4_CLAIM_STATE_ZOHO_INVOICE_CREATED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map
        "signed_by"   (get validated "signed_by")
        "verified_by" (get validated "verified_by")
        *connector-id-zoho*        (get validated *connector-id-zoho*))]

     [send (entity validated accessors)
      (let* ([signed-by (get validated "signed_by")])
        (if (not (nil? signed-by))
          (vector (mk-zoho-create-invoice-event entity (get validated *connector-id-zoho*) accessors))
          (vector)))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

(defun wf4-claim-contract-signed-state-handler ()
  (labels
    ([receive (resp entity accessors)
      (let* ([claim-id    (or (get resp "claim_id") (get entity "claim_id"))]
             [signed-by   (or (get resp "signedBy") (get entity "signed_by"))]
             [verified-by (or (get resp "verifiedBy") (get entity "verified_by") "jack.clarke@luthersystems.com")]
             [zoho       (or (get resp *connector-id-zoho*)
                            (get entity *connector-id-zoho*)
                            (sorted-map
                              "customer_id"      *wf4-default-customer-id*
                              "reference_number" (or claim-id "WF4-CLAIM-001")
                              "due_date"         *wf4-default-due-date*
                              "is_inclusive_tax" *wf4-default-is-inclusive-tax*
                              "currency_code"    *wf4-default-currency-code*
                              "line_items"       *wf4-default-line-items*))])
        (sorted-map
          "signed_by"   signed-by
          "verified_by" verified-by
          *connector-id-zoho*        zoho))]

     [validate (received entity accessors)
       (when (nil? (get received "signed_by")) (set-exception-business "missing signature"))
       received]

     [decide-next-state (validated entity accessors)
       "WF4_CLAIM_STATE_ZOHO_INVOICE_CREATED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
       (sorted-map
         "signed_by"   (get validated "signed_by")
         "verified_by" (get validated "verified_by")
         *connector-id-zoho*        (get validated *connector-id-zoho*))]

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
      (let* ([sharepoint-raw (get entity *connector-id-sharepoint*)]
             [sharepoint-args (or sharepoint-raw
                                (sorted-map
                                  "site_id"  *wf4-default-sharepoint-site-id*
                                  "drive_id" *wf4-default-sharepoint-drive-id*
                                  "item_id"  *wf4-default-sharepoint-item-id*
                                  "filename" *wf4-default-sharepoint-filename*))])
        (vector (wf4-mk-sharepoint-get-id-doc-event entity sharepoint-args accessors)))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

(defun wf4-sharepoint-doc-retrieved-state-handler ()
  (labels
    ([receive (resp entity accessors) (wf4-parse-sharepoint-docs resp)]
     [validate (received entity accessors) received]
     [decide-next-state (validated entity accessors)
       "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map "sharepoint_documents" validated)]

     [send (entity validated accessors)
      (let* ([claim-id (get entity "claim_id")]
             [servicenow-raw (get entity *connector-id-servicenow*)]
             [servicenow-args (or servicenow-raw
                                (sorted-map
                                  "short_description" (format-string "Create incident for claim {}" (or claim-id "WF4-CLAIM-001"))
                                  "description"      *wf4-default-servicenow-description*
                                  "priority"         *wf4-default-servicenow-priority*
                                  "category"         *wf4-default-servicenow-category*
                                  "impact"           *wf4-default-servicenow-impact*
                                  "urgency"          *wf4-default-servicenow-urgency*
                                  "assignment_group" *wf4-default-servicenow-assignment-group*))])
        (vector (mk-servicenow-create-incident-event entity servicenow-args accessors)))])

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

(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; State handlers for Workflow 4 (Zoho → SharePoint → ServiceNow)
;; -----------------------------------------------------------------------------
;; Simple init handler for unified process - transitions to WAITING_FOR_SIGNATURE with no events

(defun wf4-claim-init-simple-state-handler ()
  (labels
    ([parse (resp entity)
      (cc:infof (sorted-map
                  "resp" resp
                  "entity" entity)
                "wf4-claim-init-simple-state-handler: parse")
      ;; Simple init - just extract claim_id
      (let* ([claim-id (or (get resp "claim_id") (get entity "claim_id"))])
        (when (nil? claim-id)
          (set-exception-business "missing claim_id"))
        (sorted-map "claim_id" claim-id))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors) ()]
     [create-events (entity parsed accessors) (vector)])
    (mk-state-handler
      :next            "WF4_CLAIM_STATE_WAITING_FOR_SIGNATURE"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf4-claim-waiting-for-signature-state-handler ()
  (labels
    ([parse (resp entity)
      (cc:infof (sorted-map
                  "resp" resp
                  "entity" entity)
                "wf4-claim-waiting-for-signature-state-handler: parse")
      ;; Waiting state - accepts signedBy/verifiedBy when external system calls /contract-signed
      ;; When external endpoint calls, resp contains signedBy/verifiedBy and we create Zoho event directly
      ;; During unified process transition, resp is empty - just wait (no events)
      (let* ([claim-id    (or (get resp "claim_id") (get entity "claim_id"))]
             [signed-by   (get resp "signedBy")]  ;; Only present when called from external endpoint
             [verified-by (or (get resp "verifiedBy") "jack.clarke@luthersystems.com")]
             ;; Zoho data: use existing from entity or defaults
             [zoho       (or (get resp "zoho")
                          (get entity "zoho")
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
          "zoho"        zoho))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors)
      ;; Store signedBy/verifiedBy and Zoho config
      (sorted-map
        "signed_by"   (get parsed "signed_by")
        "verified_by" (get parsed "verified_by")
        "zoho"        (get parsed "zoho"))]
     [create-events (entity parsed accessors)
      ;; Create Zoho invoice event directly when signedBy is present (from external endpoint)
      ;; During unified process transition, signedBy will be nil, so no events (will pause)
      (let* ([signed-by (get parsed "signed_by")]
             [has-signature (not (nil? signed-by))])
        (if has-signature
          ;; External endpoint called - create Zoho event and transition to ZOHO_INVOICE_CREATED
          (vector (mk-zoho-create-invoice-event entity (get parsed "zoho")))
          ;; Unified process transition - no events, will pause here
          (vector)))])
    (mk-state-handler
      :next            "WF4_CLAIM_STATE_ZOHO_INVOICE_CREATED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))
(defun wf4-claim-contract-signed-state-handler ()
  (labels
    ([parse (resp entity)
      ;; Parse contract signed data and prepare Zoho invoice data
      ;; signedBy and verifiedBy come from the request body (inbound) or entity (unified process)
      ;; Zoho data comes from entity (if already set) or defaults
      (let* ([claim-id    (or (get resp "claim_id") (get entity "claim_id"))]
             ;; signedBy comes from resp (external endpoint) or entity (stored by WAITING_FOR_SIGNATURE)
             ;; During unified process transition, resp is empty, so get from entity
             [signed-by   (or (get resp "signedBy")
                              (get entity "signed_by"))]
             [verified-by (or (get resp "verifiedBy")
                              (get entity "verified_by")
                              "jack.clarke@luthersystems.com")]
             ;; Zoho data: use existing from entity or defaults
             [zoho       (or (get resp "zoho")
                            (get entity "zoho")
                            (sorted-map
                              "customer_id"      *wf4-default-customer-id*
                              "reference_number" (or claim-id "WF4-CLAIM-001")
                              "due_date"         *wf4-default-due-date*
                              "is_inclusive_tax" *wf4-default-is-inclusive-tax*
                              "currency_code"    *wf4-default-currency-code*
                              "line_items"       *wf4-default-line-items*))])
        (cc:infof (sorted-map
                    "claim_id" claim-id
                    "current_state" (get entity "state")
                    "has_signed_by" (not (nil? signed-by))
                    "signed_by" signed-by
                    "verified_by" verified-by
                    "signed_by_source" (if (get resp "signedBy") "resp" "entity")
                    "resp_keys" (if resp (keys resp) (vector))
                    "entity_keys" (keys entity))
                  "wf4-claim-contract-signed-state-handler: parse - arrived at CONTRACT_SIGNED, preparing Zoho invoice")
        (sorted-map
          "signed_by"   signed-by
          "verified_by" verified-by
          "zoho"        zoho))]
     [stage-ephemeral (entity parsed accessors)
       (vector)]
     [stage-durable (entity parsed accessors)
       ;; Store signed data and Zoho config
       (sorted-map
         "signed_by"   (get parsed "signed_by")
         "verified_by" (get parsed "verified_by")
         "zoho"        (get parsed "zoho"))]
     [create-events (entity parsed accessors)
       ;; Create Zoho invoice event to transition to ZOHO_INVOICE_CREATED
       (cc:infof (sorted-map
                   "claim_id" (get entity "claim_id"))
                 "wf4-claim-contract-signed-state-handler: create-events - creating Zoho invoice event")
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
      ;; Get SharePoint data from entity or use defaults
      (let* ([sharepoint-raw (get entity "sharepoint")]
             [sharepoint-args (or sharepoint-raw
                                (sorted-map
                                  "site_id"  *wf4-default-sharepoint-site-id*
                                  "drive_id" *wf4-default-sharepoint-drive-id*
                                  "item_id"  *wf4-default-sharepoint-item-id*
                                  "filename" *wf4-default-sharepoint-filename*))])
        (vector (wf4-mk-sharepoint-get-id-doc-event entity sharepoint-args)))])
    (mk-state-handler
      :next            "WF4_CLAIM_STATE_SHAREPOINT_DOC_RETRIEVED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf4-sharepoint-doc-retrieved-state-handler ()
  (labels
    ([parse (resp entity)
      (let* ([documents (wf4-parse-sharepoint-docs resp)])
        (assoc documents "retrieved_at" "2025-11-11"))]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map "sharepoint_documents" parsed)]
     [create-events (entity parsed accessors)
      ;; Get ServiceNow data from entity or use defaults
      (let* ([claim-id (get entity "claim_id")]
             [servicenow-raw (get entity "servicenow")]
             [servicenow-args (or servicenow-raw
                                (sorted-map
                                  "short_description" (format-string "Create incident for claim {}" (or claim-id "WF4-CLAIM-001"))
                                  "description"      *wf4-default-servicenow-description*
                                  "priority"         *wf4-default-servicenow-priority*
                                  "category"         *wf4-default-servicenow-category*
                                  "impact"           *wf4-default-servicenow-impact*
                                  "urgency"          *wf4-default-servicenow-urgency*
                                  "assignment_group" *wf4-default-servicenow-assignment-group*))])
        (vector (mk-servicenow-create-incident-event entity servicenow-args)))])
    (mk-state-handler
      :next            "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf4-servicenow-incident-created-state-handler (&optional next-state after-storage-hook)
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
      :next            (or next-state "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED")
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events
      :after-storage-hook after-storage-hook)))


;; build-event moved to substr_generic_parser.lisp

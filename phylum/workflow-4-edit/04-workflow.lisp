(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; State handlers for Workflow 4 (Zoho → SharePoint → ServiceNow)
;; -----------------------------------------------------------------------------

(defun wf4-claim-waiting-for-signature-state-handler ()
  (labels
    ([parse (resp entity)
      ;; Waiting state - accepts signedBy/verifiedBy when external system calls /contract-signed
      ;; During unified process transition, resp is empty - just wait
      ;; When external endpoint calls, resp contains signedBy/verifiedBy
      (let* ([claim-id    (or (get resp "claim_id") (get entity "claim_id"))]
             [signed-by   (get resp "signedBy")]  ;; Only present when called from external endpoint
             [verified-by (or (get resp "verifiedBy") "jack.clarke@luthersystems.com")])
        ;; During unified process transition, resp is empty so signedBy will be nil - that's OK
        ;; When external endpoint calls, signedBy will be present
        (sorted-map
          "claim_id"    claim-id
          "signed_by"   signed-by
          "verified_by" verified-by))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors)
      ;; Store signedBy/verifiedBy if provided (from external endpoint)
      ;; During unified process transition, these will be nil and won't be stored
      (if (get parsed "signed_by")
        (sorted-map
          "signed_by"   (get parsed "signed_by")
          "verified_by" (get parsed "verified_by"))
        ())]  ;; Empty map during unified process transition
     [create-events (entity parsed accessors) (vector)])
    (mk-state-handler
      :next            "WF4_CLAIM_STATE_CONTRACT_SIGNED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events
      :immediate-next  false  ;; Don't auto-transition - wait for external endpoint to trigger
      :terminal        true)))  ;; Terminal state - waits for external input via /contract-signed endpoint

(defun wf4-claim-contract-signed-state-handler ()
  (labels
    ([parse (resp entity)
      ;; Parse contract signed data from inbound REST endpoint or unified process transition
      ;; signedBy and verifiedBy come from the request body (inbound) or entity (unified process)
      ;; For unified process: resp may be empty, so we get signedBy/verifiedBy from entity or use defaults
      (let* ([claim-id    (or (get resp "claim_id") (get entity "claim_id"))]
             ;; signedBy comes from resp (external endpoint) or entity (stored by WAITING_FOR_SIGNATURE)
             ;; During unified process transition, resp is empty, so get from entity
             [signed-by   (or (get resp "signedBy")
                              (get entity "signed_by"))]
             [verified-by (or (get resp "verifiedBy")
                              (get entity "verified_by")
                              "jack.clarke@luthersystems.com")])
        (when (nil? claim-id)
          (set-exception-business "missing claim_id"))
        (sorted-map
          "claim_id"    claim-id
          "signed_by"   signed-by
          "verified_by" verified-by))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "claim_id"    (get parsed "claim_id")
        "signed_by"   (get parsed "signed_by")
        "verified_by" (get parsed "verified_by"))]
     [create-events (entity parsed accessors) (vector)])
    (mk-state-handler
      :next            "WF4_CLAIM_STATE_INIT"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events
      :immediate-next  true)))

(defun wf4-claim-init-state-handler ()
  (labels
    ([parse (resp entity)
      ;; Prioritize resp (explicit request) over entity (accumulated data), then defaults
      ;; For unified process, resp is empty so falls back to entity
      (let* ([claim-id   (or (get resp "claim_id") (get entity "claim_id"))]
             [policy-id  (or (get resp "policy_id") (get entity "policy_id") *wf4-default-policy-id*)]
             ;; Hardcode defaults for now
             [zoho       (or (get resp "zoho")
                            (get entity "zoho")
                            (sorted-map
                              "customer_id"      *wf4-default-customer-id*
                              "reference_number" (or claim-id "WF4-CLAIM-001")
                              "due_date"         *wf4-default-due-date*
                              "is_inclusive_tax" *wf4-default-is-inclusive-tax*
                              "currency_code"    *wf4-default-currency-code*
                              "line_items"       *wf4-default-line-items*))]
             [sharepoint (or (get resp "sharepoint")
                            (get entity "sharepoint")
                            (sorted-map
                              "site_id"  *wf4-default-sharepoint-site-id*
                              "drive_id" *wf4-default-sharepoint-drive-id*
                              "item_id"  *wf4-default-sharepoint-item-id*
                              "filename" *wf4-default-sharepoint-filename*))]
             [servicenow (or (get resp "servicenow")
                            (get entity "servicenow")
                            (sorted-map
                              "short_description" (format-string "Create incident for claim {}" (or claim-id "WF4-CLAIM-001"))
                              "description"      *wf4-default-servicenow-description*
                              "priority"         *wf4-default-servicenow-priority*
                              "category"         *wf4-default-servicenow-category*
                              "impact"           *wf4-default-servicenow-impact*
                              "urgency"          *wf4-default-servicenow-urgency*
                              "assignment_group" *wf4-default-servicenow-assignment-group*))])
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
      (vector (wf4-mk-sharepoint-get-id-doc-event entity (get entity "sharepoint")))])
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
      (vector (mk-servicenow-create-incident-event entity (get entity "servicenow")))])
    (mk-state-handler
      :next            "WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf4-servicenow-incident-created-state-handler (&optional next-state)
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
      :next            (or next-state "WF4_CLAIM_STATE_DONE")
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events
      :immediate-next  (if next-state true false))))

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
      :immediate-next  (if next-state true false)
      :terminal        (not next-state))))

;; build-event moved to substr_generic_parser.lisp

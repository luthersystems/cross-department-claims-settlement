
;; =============================
;; 11) SMTP_DISPATCHED -> DOCMAGIC_REVIEWED
;; DocMagic: compliance review
;; =============================
(defun claim-smtp-dispatched-state-handler ()
  (labels
    ([parse (resp entity) (parse-smtp-send resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map "email_message_id" (get parsed "message_id") "loop" 11)]
     [create-events (entity parsed accessors)
      (vector (mk-docmagic-review-event entity
                (sorted-map "invoice_id" (get entity "invoice_id")
                            "amount"    (get entity "amount")
                            "claim_id"  (get entity "claim_id"))))])
  (mk-state-handler
    :next            "CLAIM_STATE_DOCMAGIC_REVIEWED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 12) DOCMAGIC_REVIEWED -> SP_COMPLIANCE_OK
;; SharePoint: fetch compliance artefacts/approvals
;; =============================
(defun claim-docmagic-reviewed-state-handler ()
  (labels
    ([parse (resp entity) (parse-docmagic-review resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map "docmagic_status" (get parsed "status")
                  "docmagic_flags" (get parsed "flags")
                  "loop"           12)]
     [create-events (entity parsed accessors)
      (vector (mk-sharepoint-fetch-compliance-event entity
                (sorted-map "invoice_id" (get entity "invoice_id")
                            "folder"    (compliance-folder entity))))])
  (mk-state-handler
    :next            "CLAIM_STATE_SP_COMPLIANCE_OK"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 13) SP_COMPLIANCE_OK -> SERVICENOW_APPROVED
;; ServiceNow approval ticket check
;; =============================
(defun claim-sp-compliance-ok-state-handler ()
  (labels
    ([parse (resp entity) (parse-sharepoint-compliance resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map "compliance_refs" (get parsed "docIds") "loop" 13)]
     [create-events (entity parsed accessors)
      (vector (mk-servicenow-check-approval-event entity
                (sorted-map "invoice_id" (get entity "invoice_id")
                            "amount"    (get entity "amount"))))])
  (mk-state-handler
    :next            "CLAIM_STATE_SERVICENOW_APPROVED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))
(defun wf2-claim-init-state-handler ()
  (labels
    ([parse (resp entity)
      ;; resp can be empty; we drive off entity.claim_id/policy_id
      ;; Also capture optional fields for workflow 3 chaining
      (let* ([guidewire-claim-id (or (get entity "guidewire_claim_id")
                                     (get entity "gw_claim_id")
                                     (get resp "guidewire_claim_id")
                                     (get resp "gw_claim_id")
                                     (get entity "claim_id"))]
             [policy-id (or (get entity "policy_id") (get resp "policy_id"))]
             [signer-email (or (get entity "signer_email") (get resp "signer_email"))]
             [invoice-amount (or (get entity "invoice_amount") (get resp "invoice_amount"))]
             [signer-name (or (get entity "signer_name") (get resp "signer_name"))]
             [originator-name (or (get entity "originator_name") (get resp "originator_name"))]
             [recipient-name (or (get entity "recipient_name") (get resp "recipient_name"))]
             [issue-date (or (get entity "issue_date") (get resp "issue_date"))])
        (sorted-map
          "guidewire_claim_id"  guidewire-claim-id
          "gw_claim_id"         guidewire-claim-id
          "policy_id"           policy-id
          ;; Pass through optional fields for WF3
          "signer_email"        signer-email
          "invoice_amount"      invoice-amount
          "signer_name"         signer-name
          "originator_name"     originator-name
          "recipient_name"      recipient-name
          "issue_date"          issue-date))]

     [stage-ephemeral (entity parsed accessors) ()]

     [stage-durable (entity parsed accessors)
      ;; Store all fields including optional ones for WF3
      (sorted-map
        "guidewire_claim_id"  (get parsed "guidewire_claim_id")
        "gw_claim_id"         (get parsed "gw_claim_id")
        "policy_id"           (get parsed "policy_id")
        "signer_email"        (get parsed "signer_email")
        "invoice_amount"      (get parsed "invoice_amount")
        "signer_name"         (get parsed "signer_name")
        "originator_name"     (get parsed "originator_name")
        "recipient_name"      (get parsed "recipient_name")
        "issue_date"          (get parsed "issue_date"))]

     [create-events (entity parsed accessors)
      (vector (mk-guidewire-get-claim-event entity (get parsed "guidewire_claim_id")))])

    (mk-state-handler
      :next            "WF2_CLAIM_STATE_GUIDEWIRE_SNAPSHOTTED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

;; =============================
;; 5) GUIDEWIRE_SNAPSHOTTED -> MYSQL_VALIDATED
;; MySQL policy check (may run in parallel with SharePoint docs fetch)
;; =============================
(defun wf2-claim-guidewire-snapshotted-state-handler ()
  (labels
    ([parse (resp entity) (parse-guidewire-claim (parse-generic-resp resp))] ; create
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (cc:infof (sorted-map "status" (get parsed "status")) "guidewire parsed status in durable")
      (sorted-map "guidewire_status" (get parsed "status"))]
     [create-events (entity parsed accessors)
      (vector (mk-mysql-check-policy-event entity ; create
                (sorted-map "policy_id" *wf2-default-policy-id*
                            "claim_id"  *wf2-default-claim-id*)))])
  (mk-state-handler
    :next            "WF2_CLAIM_STATE_MYSQL_VALIDATED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 6) MYSQL_VALIDATED -> SP_DOCS_COLLECTED
;; SharePoint: collect supporting docs
;; =============================
(defun wf2-claim-mysql-validated-state-handler ()
  (labels
    ([parse (resp entity) 
      (cc:infof (sorted-map "resp" resp) "parse mysql resp")
        (parse-mysql-policy (parse-generic-resp resp))
      ] ; create
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "policy_status"  (get parsed "status")
        "coverage_limit" (get parsed "coverage_limit"))]
     [create-events (entity parsed accessors)
  (vector
    (mk-sharepoint-get-id-doc-event
      entity
      (sorted-map
        "site_id"  *wf2-default-sharepoint-site-id*
        "drive_id" *wf2-default-sharepoint-drive-id*
        "item_id"  *wf2-default-sharepoint-item-id*
        "filename" *wf2-default-sharepoint-filename*)))])
  (mk-state-handler
    :next            "WF2_CLAIM_STATE_SP_DOCS_COLLECTED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 7) SP_DOCS_COLLECTED -> GUIDEWIRE_APPROVED
;; Update/sync approval in Guidewire
;; =============================

(defun wf2-claim-sp-docs-collected-state-handler ()
  (labels
    ([parse (resp entity) (parse-sharepoint-docs resp)] ; create
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors) (sorted-map "sp_docs" (get parsed "documents"))]
     [create-events (entity parsed accessors)
        (vector (mk-guidewire-approval-update-event entity  ; create
                 (sorted-map "claim_id" (get entity "claim_id")
                             "approval" "approved"
                             "approved_by" (get entity "handler"))))] )
  (mk-state-handler
    :next            "WF2_CLAIM_STATE_GUIDEWIRE_APPROVED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))

;;;; guidewire (start)

;; =============================
;; 8) GUIDEWIRE_APPROVED -> (handoff to WF3)
;; After Guidewire approval, hand off to workflow 3 (invoice generation)
;; =============================
(defun wf2-claim-guidewire-approved-state-handler (&optional next-state)
  (labels
    ([parse (resp entity) (parse-guidewire-approval-update resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "approval_status" (get parsed "approval_status")
        "approval_confirmation" (get parsed "confirmation"))]
     [create-events (entity parsed accessors)
      (vector)])
    (mk-state-handler
      :next            (or next-state "WF2_CLAIM_STATE_DONE")
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events
      :immediate-next  (if next-state true false))))

(defun wf2-claim-done-state-handler (&optional next-state)
  (labels
    ([parse (resp entity) (parse-generic-resp resp)]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors) ()]
     [create-events (entity parsed accessors) ()])
    (mk-state-handler
      :next            (or next-state "WF2_CLAIM_STATE_DONE")
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events
      :immediate-next  (if next-state true false))))

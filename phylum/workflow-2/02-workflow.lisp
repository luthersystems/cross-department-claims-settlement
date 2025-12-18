(defun wf2-claim-init-state-handler ()
  (labels
    ([parse (resp entity accessors)
      ;; Prioritize resp (explicit request) over entity (accumulated data)
      ;; For unified process, resp is empty so falls back to entity
      (let* ([guidewire-claim-id (or (get resp "guidewire_claim_id")
                                     (get resp "gw_claim_id")
                                     (get entity "guidewire_claim_id")
                                     (get entity "gw_claim_id")
                                     (get entity "claim_id"))]
             [policy-id (or (get resp "policy_id") (get entity "policy_id"))]
             [signer-email (or (get resp "signer_email") (get entity "signer_email"))]
             [invoice-amount (or (get resp "invoice_amount") (get entity "invoice_amount"))]
             [signer-name (or (get resp "signer_name") (get entity "signer_name"))]
             [originator-name (or (get resp "originator_name") (get entity "originator_name"))]
             [recipient-name (or (get resp "recipient_name") (get entity "recipient_name"))]
             [issue-date (or (get resp "issue_date") (get entity "issue_date"))])
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

     [stage-ephemeral (entity parsed accessors) (vector)]

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
      (vector (mk-guidewire-get-claim-event entity (get parsed "guidewire_claim_id") accessors))])

    (mk-state-handler
      :next            "WF2_CLAIM_STATE_GUIDEWIRE_SNAPSHOTTED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

;; =============================
;; 1) GUIDEWIRE_SNAPSHOTTED -> MYSQL_VALIDATED
;; MySQL policy check (may run in parallel with SharePoint docs fetch)
;; =============================
(defun wf2-claim-guidewire-snapshotted-state-handler ()
  (labels
    ([parse (resp entity accessors) (parse-guidewire-claim (parse-generic-resp resp))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors)
      (sorted-map "guidewire_status" (get parsed "status"))]
     [create-events (entity parsed accessors)
      (vector (mk-mysql-check-policy-event entity (sorted-map "policy_id" (get entity "policy_id")) accessors))])
  (mk-state-handler
    :next            "WF2_CLAIM_STATE_MYSQL_VALIDATED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 2) MYSQL_VALIDATED -> SP_DOCS_COLLECTED
;; SharePoint: collect supporting docs
;; =============================
(defun wf2-claim-mysql-validated-state-handler ()
  (labels
    ([parse (resp entity accessors) 
        (parse-mysql-policy (parse-generic-resp resp))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "policy_status"  (get parsed "status")
        "coverage_limit" (get parsed "coverage_limit"))]
     [create-events (entity parsed accessors)
  (vector
        (wf2-mk-sharepoint-get-id-doc-event
      entity
      (sorted-map
        "site_id"  *wf2-default-sharepoint-site-id*
        "drive_id" *wf2-default-sharepoint-drive-id*
        "item_id"  *wf2-default-sharepoint-item-id*
        "filename" *wf2-default-sharepoint-filename*)
      accessors))])
  (mk-state-handler
    :next            "WF2_CLAIM_STATE_SP_DOCS_COLLECTED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 3) SP_DOCS_COLLECTED -> GUIDEWIRE_APPROVED
;; Update/sync approval in Guidewire
;; =============================

(defun wf2-claim-sp-docs-collected-state-handler ()
  (labels
    ([parse (resp entity accessors) (wf2-parse-sharepoint-docs resp)]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors) (sorted-map "sp_docs" (get parsed "documents"))]
     [create-events (entity parsed accessors)
        (vector (mk-guidewire-approval-update-event entity (sorted-map "claim_id" (get entity "claim_id") "approval" "Approved" "approved_by" "Handler") accessors))])
  (mk-state-handler
    :next            "WF2_CLAIM_STATE_GUIDEWIRE_APPROVED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 4) GUIDEWIRE_APPROVED
;; Update Guidewire approval status and complete workflow
;; =============================
(defun wf2-claim-guidewire-approved-state-handler (&optional next-state after-storage-hook)
  (labels
    ([parse (resp entity accessors) (parse-guidewire-approval-update resp)]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "approval_status" (get parsed "approval_status")
        "approval_confirmation" (get parsed "confirmation"))]
     [create-events (entity parsed accessors)
      (vector)])
    (mk-state-handler
      :next            (or next-state "WF2_CLAIM_STATE_GUIDEWIRE_APPROVED")
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events
      :after-storage-hook after-storage-hook)))

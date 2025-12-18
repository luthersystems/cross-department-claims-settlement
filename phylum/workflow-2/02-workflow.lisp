(in-package 'cdcs)

;; =============================
;; 1) INIT -> GUIDEWIRE_SNAPSHOTTED
;; Guidewire claim fetch
;; =============================

(defun wf2-claim-init-state-handler ()
  (labels
    ([receive (resp entity accessors)
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
          "signer_email"        signer-email
          "invoice_amount"      invoice-amount
          "signer_name"         signer-name
          "originator_name"     originator-name
          "recipient_name"      recipient-name
          "issue_date"          issue-date))]

     [validate (received entity accessors)
       (when (nil? (get received "guidewire_claim_id")) (set-exception-business "missing guidewire_claim_id"))
       received]

     [decide-next-state (validated entity accessors)
       "WF2_CLAIM_STATE_GUIDEWIRE_SNAPSHOTTED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map
        "guidewire_claim_id"  (get validated "guidewire_claim_id")
        "gw_claim_id"         (get validated "gw_claim_id")
        "policy_id"           (get validated "policy_id")
        "signer_email"        (get validated "signer_email")
        "invoice_amount"      (get validated "invoice_amount")
        "signer_name"         (get validated "signer_name")
        "originator_name"     (get validated "originator_name")
        "recipient_name"      (get validated "recipient_name")
        "issue_date"          (get validated "issue_date"))]

     [send (entity validated accessors)
      (vector (mk-guidewire-get-claim-event entity (get validated "guidewire_claim_id") accessors))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

;; =============================
;; 2) GUIDEWIRE_SNAPSHOTTED -> MYSQL_VALIDATED
;; MySQL policy check
;; =============================

(defun wf2-claim-guidewire-snapshotted-state-handler ()
  (labels
    ([receive (resp entity accessors)
       (parse-guidewire-claim (parse-generic-resp resp))]

     [validate (received entity accessors)
       (when (nil? (get received "status")) (set-exception-business "missing status in guidewire response"))
       received]

     [decide-next-state (validated entity accessors)
       "WF2_CLAIM_STATE_MYSQL_VALIDATED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map "guidewire_status" (get validated "status"))]

     [send (entity validated accessors)
      (vector (mk-mysql-check-policy-event entity (sorted-map "policy_id" (get entity "policy_id")) accessors))])

  (mk-state-handler
    :receive           receive
    :validate          validate
    :decide-next-state decide-next-state
    :store-ephemeral   store-ephemeral
    :store-durable     store-durable
    :send              send)))


;; =============================
;; 3) MYSQL_VALIDATED -> SP_DOCS_COLLECTED
;; SharePoint: collect supporting docs
;; =============================

(defun wf2-claim-mysql-validated-state-handler ()
  (labels
    ([receive (resp entity accessors) 
        (parse-mysql-policy (parse-generic-resp resp))]

     [validate (received entity accessors)
       (when (nil? (get received "status")) (set-exception-business "missing status in mysql response"))
       received]

     [decide-next-state (validated entity accessors)
       "WF2_CLAIM_STATE_SP_DOCS_COLLECTED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map
        "policy_status"  (get validated "status")
        "coverage_limit" (get validated "coverage_limit"))]

     [send (entity validated accessors)
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
    :receive           receive
    :validate          validate
    :decide-next-state decide-next-state
    :store-ephemeral   store-ephemeral
    :store-durable     store-durable
    :send              send)))


;; =============================
;; 4) SP_DOCS_COLLECTED -> GUIDEWIRE_APPROVED
;; Update/sync approval in Guidewire
;; =============================

(defun wf2-claim-sp-docs-collected-state-handler ()
  (labels
    ([receive (resp entity accessors)
       (wf2-parse-sharepoint-docs resp)]

     [validate (received entity accessors)
       (when (nil? (get received "documents")) (set-exception-business "missing documents in sharepoint response"))
       received]

     [decide-next-state (validated entity accessors)
       "WF2_CLAIM_STATE_GUIDEWIRE_APPROVED"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
       (sorted-map "sp_docs" (get validated "documents"))]

     [send (entity validated accessors)
        (vector (mk-guidewire-approval-update-event entity (sorted-map "claim_id" (get entity "claim_id") "approval" "Approved" "approved_by" "Handler") accessors))])

  (mk-state-handler
    :receive           receive
    :validate          validate
    :decide-next-state decide-next-state
    :store-ephemeral   store-ephemeral
    :store-durable     store-durable
    :send              send)))


;; =============================
;; 5) GUIDEWIRE_APPROVED
;; Update Guidewire approval status and complete workflow
;; =============================

(defun wf2-claim-guidewire-approved-state-handler (&optional next-state after-storage-hook)
  (labels
    ([receive (resp entity accessors)
       (parse-guidewire-approval-update resp)]

     [validate (received entity accessors)
       (when (nil? (get received "approval_status")) (set-exception-business "missing approval_status in guidewire update response"))
       received]

     [decide-next-state (validated entity accessors)
       (or next-state "WF2_CLAIM_STATE_GUIDEWIRE_APPROVED")]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map
        "approval_status" (get validated "approval_status")
        "approval_confirmation" (get validated "confirmation"))]

     [send (entity validated accessors) (vector)])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send
      :after-storage-hook after-storage-hook)))

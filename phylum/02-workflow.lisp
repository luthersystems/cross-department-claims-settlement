(defun wf2-claim-init-state-handler ()
  (labels
    ([parse (resp entity)
      ;; resp can be empty; we drive off entity.claim_id/policy_id
      ;; Also capture optional fields for workflow 3 chaining
      (let* ([claim-id  (or (get entity "claim_id")  (get resp "guidewire_claim_id"))]
             [policy-id (or (get entity "policy_id") (get resp "policy_id"))]
             [chain-flag (normalize-bool (get resp "chain_to_wf3") *wf2-chain-enabled*)])
        (sorted-map
          "guidewire_claim_id"  claim-id
          "policy_id"           policy-id
          ;; Pass through optional fields for WF3
          "signer_email"        (get resp "signer_email")
          "invoice_amount"      (get resp "invoice_amount")
          "signer_name"         (get resp "signer_name")
          "originator_name"     (get resp "originator_name")
          "recipient_name"      (get resp "recipient_name")
          "issue_date"          (get resp "issue_date")
          "chain_to_wf3"        chain-flag))]

     [stage-ephemeral (entity parsed accessors) ()]

     [stage-durable (entity parsed accessors)
      ;; Store all fields including optional ones for WF3
      (sorted-map
        "guidewire_claim_id"  (get parsed "claim_id")
        "policy_id"           (get parsed "policy_id")
        "signer_email"        (get parsed "signer_email")
        "invoice_amount"      (get parsed "invoice_amount")
        "signer_name"         (get parsed "signer_name")
        "originator_name"     (get parsed "originator_name")
        "recipient_name"      (get parsed "recipient_name")
        "issue_date"          (get parsed "issue_date")
        "chain_to_wf3"        (get parsed "chain_to_wf3"))]

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
                (sorted-map "policy_id" (get entity "policy_id")
                            "claim_id"  (get entity "claim_id"))))])
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
        "site_id"  "samwoodluthersystems.sharepoint.com,af554837-6d2d-48e7-aa08-9584e15df76e,28227d76-23e6-4218-85c5-0473c0006245"
        "drive_id" "b!N0hVry1t50iqCJWE4V33bnZ9IijmIxhChcUEc8AAYkU0cfiPk4MZRaBijb338Qw8"
        "item_id"  "01RAAXWAZH6LCSA5FLHRE2QJXBSIVDOGV4"
        "filename" "id-verification.txt")))])
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
(defun wf2-claim-guidewire-approved-state-handler ()
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
      :next            "WF2_CLAIM_STATE_DONE"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf2-claim-done-state-handler ()
  (labels
    ([parse (resp entity) (parse-generic-resp resp)]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors) ()]
     [create-events (entity parsed accessors) ()])
    (mk-state-handler
      :next            "WF2_CLAIM_STATE_DONE"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

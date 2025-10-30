
;; =============================
;; 8) GUIDEWIRE_APPROVED -> BASWARE_INVOICED
;; Basware: create inter‑entity invoice
;; =============================
(defun claim-guidewire-approved-state-handler ()
  (labels
    ([parse (resp entity) (parse-guidewire-approval resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map "approval" (get parsed "approval"))]
     [create-events (entity parsed accessors)
      (vector (mk-basware-create-invoice-event entity ; create
                (sorted-map
                  "claim_id"  (get entity "claim_id")
                  "policy_id" (get entity "policy_id")
                  "amount"    (calc-invoice-amount entity) ; create
                  "memo"      "Inter-entity settlement")))])
  (mk-state-handler
    :next            "CLAIM_STATE_BASWARE_INVOICED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 9) BASWARE_INVOICED -> SF_SYNCED
;; Salesforce: sync invoice summary
;; =============================
(defun claim-basware-invoiced-state-handler ()
  (labels
    ([parse (resp entity) (parse-basware-create resp)]
     [stage-ephemeral (entity parsed accessors)
      ;; hold a transient pointer that DocMagic could also use later
      (vector (sorted-map :key "invoice_ref"
                          :value (or (get parsed "invoice_ref")
                                     (format-string "basware:{}" (get parsed "invoice_id")))
                          :drop-state "CLAIM_STATE_SF_SYNCED"))]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "invoice_id" (get parsed "invoice_id"))]
     [create-events (entity parsed accessors)
      (vector (mk-salesforce-sync-invoice-event entity ; create
                (sorted-map "invoice_id" (get entity "invoice_id")
                            "claim_id"  (get entity "claim_id")
                            "amount"    (get entity "amount"))))])
  (mk-state-handler
    :next            "CLAIM_STATE_SF_SYNCED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 10) SF_SYNCED -> SMTP_DISPATCHED
;; Send invoice for review by email (link or attachment)
;; =============================
(defun claim-sf-synced-state-handler ()
  (labels
    ([parse (resp entity) (parse-salesforce-upsert resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors) (sorted-map "loop" 10)]
     [create-events (entity parsed accessors)
      (vector (mk-smtp-send-invoice-event entity
                (sorted-map "to" (resolve-invoice-recipient entity)
                            "subject" (fmt "Invoice %s for claim %s"
                                            (get entity "invoice_id")
                                            (get entity "claim_id"))
                            "bodyRef" (or (get entity "invoice_link")
                                           (mk-default-invoice-link entity)))))] )
  (mk-state-handler
    :next            "CLAIM_STATE_SMTP_DISPATCHED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))
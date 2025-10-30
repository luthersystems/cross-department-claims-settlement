

;; =============================
;; 14) SERVICENOW_APPROVED -> SAP_PAID
;; SAP/Allianz BS: execute payment
;; =============================
(defun claim-servicenow-approved-state-handler ()
  (labels
    ([parse (resp entity) (parse-servicenow-approval resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map "sn_state" (get parsed "state") "loop" 14)]
     [create-events (entity parsed accessors)
      (vector (mk-sap-execute-payment-event entity
                (sorted-map "invoice_id"    (get entity "invoice_id")
                            "claim_id"      (get entity "claim_id")
                            "amount"        (get entity "amount")
                            "payment_memo"  "Inter-entity settlement")))])
  (mk-state-handler
    :next            "CLAIM_STATE_SAP_PAID"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 15) SAP_PAID -> NETSUITE_RECONCILED
;; NetSuite: reconciliation entry
;; =============================
(defun claim-sap-paid-state-handler ()
  (labels
    ([parse (resp entity) (parse-sap-payment resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map "payment_txn_id" (get parsed "transaction_id")
                  "paid_amount"   (get parsed "amount")
                  "gl_post_ref"   (get parsed "posting_ref")
                  "loop"          15)]
     [create-events (entity parsed accessors)
      (vector (mk-netsuite-record-recon-event entity
                (sorted-map "invoice_id" (get entity "invoice_id")
                            "claim_id"  (get entity "claim_id")
                            "amount"    (get entity "paid_amount")
                            "txn_id"    (get entity "payment_txn_id"))))])
  (mk-state-handler
    :next            "CLAIM_STATE_NETSUITE_RECONCILED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 16) NETSUITE_RECONCILED -> DONE
;; Aggregate final status and complete
;; =============================
(defun claim-netsuite-reconciled-state-handler ()
  (labels
    ([parse (resp entity) (parse-netsuite-recon resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "recon_entry_id" (get parsed "entry_id")
        "final_status"   (decide-final-status entity)
        "loop"           16)]
     [create-events (entity parsed accessors)
      (vector)])
  (mk-state-handler
    :next            "CLAIM_STATE_DONE"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))

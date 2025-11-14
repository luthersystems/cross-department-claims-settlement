(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; State handlers for Workflow 5 (D365FO payment journal + SAP HANA recording)
;; -----------------------------------------------------------------------------

;; Simple init handler for unified process - transitions to AWAITING_PAYMENT_UPDATE with no events
(defun wf5-claim-init-state-handler ()
  (labels
    ([parse (resp entity)
      ;; Simple init - just extract claim_id
      (let* ([claim-id (or (get resp "claim_id") (get entity "claim_id"))])
        (when (nil? claim-id)
          (set-exception-business "missing claim_id"))
        (sorted-map "claim_id" claim-id))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors) ()]
     [create-events (entity parsed accessors) (vector)])
    (mk-state-handler
      :next            "WF5_CLAIM_STATE_AWAITING_PAYMENT_UPDATE"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

;; Handler for awaiting payment update - waits for external payment status update
(defun wf5-claim-awaiting-payment-update-state-handler ()
  (labels
    ([parse (resp entity)
      ;; Prioritize resp (explicit request) over entity (accumulated data), then defaults
      ;; For unified process, resp contains payment_id/status from inbound REST, entity has accumulated data
      (let* ([claim-id  (or (get resp "claim_id") (get entity "claim_id"))]
             [policy-id (or (get resp "policy_id") (get entity "policy_id") "POL-8872")]
             [payment-id (get resp "payment_id")]
             [status (get resp "status")]
             [sap       (or (get resp "sap") (get entity "sap") (sorted-map))])
        (when (nil? claim-id)
          (set-exception-business "missing claim_id"))
        (sorted-map
          "claim_id"   claim-id
          "policy_id"  policy-id
          "payment_id" payment-id
          "status"    status
          "sap"        sap))]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "claim_id"   (get parsed "claim_id")
        "policy_id"  (get parsed "policy_id")
        "payment_id" (get parsed "payment_id")
        "status"     (get parsed "status")
        "sap"        (get parsed "sap"))]
     [create-events (entity parsed accessors)
      (vector (wf5-mk-d365fo-payment-event entity
                 (or (get entity "sap") (sorted-map))))])
    (mk-state-handler
      :next            "WF5_CLAIM_STATE_D365FO_PAID"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

(defun wf5-claim-payment-approved-handler ()
  (labels
    ([parse (resp entity) resp]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors) (or parsed (sorted-map))]
     [create-events (entity parsed accessors)
      ;; Create D365FO payment journal event
      (vector (wf5-mk-d365fo-payment-event entity
                 (or (get entity "sap") (sorted-map))))])
    (mk-state-handler
      :next            "WF5_CLAIM_STATE_D365FO_PAID"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

;; Handler for D365FO payment journal creation response
;; Stores D365FO data and triggers SAP HANA recording
(defun wf5-claim-d365fo-paid-handler ()
  (labels
    ([parse (resp entity) (wf5-parse-d365fo-payment resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      ;; Store D365FO payment journal data
      (sorted-map
        "d365fo_payment_txn_id" (get parsed "transaction_id")
        "d365fo_paid_amount"     (get parsed "amount")
        "d365fo_posting_ref"     (get parsed "posting_ref")
        "d365fo_status"          (get parsed "status"))]
     [create-events (entity parsed accessors)
      ;; Create SAP HANA recording event using D365FO record and entity SAP data
      (let* ([d365fo-record (get parsed "d365fo_record")]
             [sap-payload (or (get entity "sap") (sorted-map))])
        (vector (wf5-mk-sap-record-payment-event entity d365fo-record sap-payload)))])
    (mk-state-handler
      :next            "WF5_CLAIM_STATE_SAP_PAID"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

;; Handler for SAP HANA payment recording response
(defun wf5-claim-sap-paid-handler ()
  (labels
    ([parse (resp entity) (wf5-parse-sap-payment resp)]
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      ;; Store SAP HANA recording data
      (sorted-map
        "sap_payment_txn_id" (get parsed "transaction_id")
        "sap_paid_amount"    (get parsed "amount")
        "sap_posting_ref"    (get parsed "posting_ref")
        "sap_status"         (get parsed "status"))]
     [create-events (entity parsed accessors) (vector)])
    (mk-state-handler
      :next            "WF5_CLAIM_STATE_SAP_PAID"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

;; build-event moved to substr_generic_parser.lisp

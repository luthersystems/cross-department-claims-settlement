(in-package 'cdcs)

;; -----------------------------------------------------------------------------
;; State handlers for Workflow 5 (D365FO payment journal + SAP HANA recording)
;; -----------------------------------------------------------------------------

(defun wf5-claim-init-state-handler ()
  (labels
    ([receive (resp entity accessors)
      (let* ([claim-id (or (get resp "claim_id") (get entity "claim_id"))])
        (sorted-map "claim_id" claim-id))]

     [validate (received entity accessors)
       (when (nil? (get received "claim_id")) (set-exception-business "missing claim_id"))
       received]

     [decide-next-state (validated entity accessors)
       "WF5_CLAIM_STATE_AWAITING_PAYMENT_UPDATE"]

     [store-ephemeral (entity validated accessors) (vector)]
     [store-durable (entity validated accessors) (vector)]
     [send (entity validated accessors) (vector)])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

(defun wf5-claim-awaiting-payment-update-state-handler ()
  (labels
    ([receive (resp entity accessors)
      (let* ([claim-id  (or (get resp "claim_id") (get entity "claim_id"))]
             [policy-id (or (get resp "policy_id") (get entity "policy_id") "POL-8872")]
             [payment-id (get resp "payment_id")]
             [status (get resp "status")]
             [sap       (or (get resp *connector-id-sap*) (get entity *connector-id-sap*) (sorted-map))]))
        (sorted-map
          "claim_id"   claim-id
          "policy_id"  policy-id
          "payment_id" payment-id
          "status"    status
          *connector-id-sap*        sap)]

     [validate (received entity accessors)
       (when (nil? (get received "claim_id")) (set-exception-business "missing claim_id"))
       received]

     [decide-next-state (validated entity accessors)
       "WF5_CLAIM_STATE_D365FO_PAID"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map
        "policy_id"  (get validated "policy_id")
        "payment_id" (get validated "payment_id")
        "status"     (get validated "status")
        *connector-id-sap*        (get validated *connector-id-sap*))]

     [send (entity validated accessors)
      (vector (wf5-mk-d365fo-payment-event entity
                 (or (get entity *connector-id-sap*) (sorted-map))
                 accessors))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

(defun wf5-claim-payment-approved-handler ()
  (labels
    ([receive (resp entity accessors) resp]
     [validate (received entity accessors) received]
     [decide-next-state (validated entity accessors) "WF5_CLAIM_STATE_D365FO_PAID"]
     [store-ephemeral (entity validated accessors) (vector)]
     [store-durable (entity validated accessors) (or validated (sorted-map))]
     [send (entity validated accessors)
      (vector (wf5-mk-d365fo-payment-event entity
                 (or (get entity *connector-id-sap*) (sorted-map))
                 accessors))])
    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

(defun wf5-claim-d365fo-paid-handler ()
  (labels
    ([receive (resp entity accessors) (wf5-parse-d365fo-payment resp)]

     [validate (received entity accessors)
       (when (nil? (get received "transaction_id")) (set-exception-business "missing transaction_id"))
       received]

     [decide-next-state (validated entity accessors) "WF5_CLAIM_STATE_SAP_PAID"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map
        "d365fo_payment_txn_id" (get validated "transaction_id")
        "d365fo_paid_amount"     (get validated "amount")
        "d365fo_posting_ref"     (get validated "posting_ref")
        "d365fo_status"          (get validated "status"))]

     [create-events (entity validated accessors)
      (let* ([d365fo-record (get validated "d365fo_record")]
             [sap-payload (or (get entity *connector-id-sap*) (sorted-map))])
        (vector (wf5-mk-sap-record-payment-event entity d365fo-record sap-payload accessors)))])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              create-events)))

(defun wf5-claim-sap-paid-handler ()
  (labels
    ([receive (resp entity accessors) (wf5-parse-sap-payment resp)]

     [validate (received entity accessors)
       (when (nil? (get received "transaction_id")) (set-exception-business "missing transaction_id"))
       received]

     [decide-next-state (validated entity accessors) "WF5_CLAIM_STATE_SAP_PAID"]

     [store-ephemeral (entity validated accessors) (vector)]

     [store-durable (entity validated accessors)
      (sorted-map
        "sap_payment_txn_id" (get validated "transaction_id")
        "sap_paid_amount"    (get validated "amount")
        "sap_posting_ref"    (get validated "posting_ref")
        "sap_status"         (get validated "status"))]

     [send (entity validated accessors) (vector)])

    (mk-state-handler
      :receive           receive
      :validate          validate
      :decide-next-state decide-next-state
      :store-ephemeral   store-ephemeral
      :store-durable     store-durable
      :send              send)))

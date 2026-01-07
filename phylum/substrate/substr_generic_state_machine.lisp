(in-package 'cdcs)
; 

;; -----------------------------------------------------------------------------
;; CDCS Entity State Machine Framework (6-step lifecycle)
;; -----------------------------------------------------------------------------
;;
;; Core runtime + ephemeral storage layer for declarative state machines.
;;
;; Per-step flow:
;;   receive(resp, entity, accessors)           -> received (parsed response)
;;   validate(received, entity, accessors)      -> validated (checked/enriched map)
;;   decide-next-state(validated, entity, acc)  -> next-state (string)
;;   store-ephemeral(entity, validated, acc)    -> vector of ephemeral intents
;;   store-durable(entity, validated, acc)      -> partial or full durable updates
;;   send(entity, validated, acc)               -> vector of connector events
;;
;; -----------------------------------------------------------------------------


;; -----------------------------------------------------------------------------
;; Entity Manager
;; -----------------------------------------------------------------------------
(defun mk-entity-manager (entity-name entity-key initial-state states)
  (lambda ()
    (labels
      ([name () entity-name]

       ;; Key in PDC: "cdcs:<entity-name>:<entity-id>"
       [mk-storage-key (entity-id)
         (join-index-cols "cdcs" entity-name entity-id)]

       ;; persistence (PDC)
       [storage-put (entity-doc)
         (sidedb:put (mk-storage-key (get entity-doc entity-key)) entity-doc)]

       [storage-get (entity-id)
         (let* ([key (mk-storage-key entity-id)]
                [entity-doc (sidedb:get key)])
           (when entity-doc
             (mk-entity-instance entity-name entity-key initial-state states entity-doc)))]

       [storage-del (entity-id)
         (sidedb:purge (mk-storage-key entity-id))]

       ;; constructor
       [new-instance ()
         (let* ([doc      (sorted-map entity-key (mk-uuid))]
                [instance (mk-entity-instance entity-name entity-key initial-state states doc)])
           (instance 'init))]
           
      [ephemeral-get (entity-id ekey)
         (ephem-get entity-name entity-id ekey)])

      (lambda (op &rest args)
        (cond ((equal? op 'name) (apply name args))
              ((equal? op 'new)  (apply new-instance args))
              ((equal? op 'get)  (apply storage-get args))
              ((equal? op 'del)  (apply storage-del args))
              ((equal? op 'put)  (apply storage-put args))

              ((equal? op 'ephem-get)           (apply ephemeral-get args))
              (:else (error 'unknown-operation op)))))))


;; -----------------------------------------------------------------------------
;; Entity Instance
;; -----------------------------------------------------------------------------
(defun mk-entity-instance (entity-name entity-key initial-state states entity)
  (labels
    ([init ()
       (when (nil? (get entity entity-key)) (assoc! entity entity-key (mk-uuid)))
       (when (nil? (get entity "state"))     (assoc! entity "state" initial-state))
       (sorted-map "put" entity "events" (vector))]

     [handle (resp &optional ctx)
      (let* ([required-state (get ctx "required_state")]
            [current-state  (get entity "state")])
        (when (and required-state (not (equal? current-state required-state)))
          (cc:warnf (sorted-map
                      "required_state" required-state
                      "current_state"  current-state
                      "entity_id"      (get entity entity-key))
                    "callback arrived before required state")
          (error 'invalid-state
                (format-string
                  "entity not in required state (have {}, expected {})"
                  current-state required-state)))
      (run-state-step entity-name entity-key entity resp states))])


    (lambda (op &rest args)
      (cond ((equal? op 'init)   (apply init args))
            ((equal? op 'handle) (apply handle args))
            ((equal? op 'entity-state) (get entity "state"))
            (:else (error 'unknown-entity-op op))))))


;; -----------------------------------------------------------------------------
;; Step runner (Unified Accessor Context)
;; -----------------------------------------------------------------------------
(defun run-state-step (entity-name entity-key instance resp states)
  (let* ([state      (get instance "state")]
         [spec       (lookup-state-spec state states)]
         [entity-id  (get instance entity-key)]

         ;; Unified Accessors map (built early)
         [accessors (sorted-map
                :state      state
                :entity-id  entity-id
                :entity-key entity-key
                :get-ephem  (lambda (k) (ephem-get entity-name entity-id k)))]

         ;; 1) receive - parses raw response
         [received  ((spec-receive spec) resp instance accessors)]

         ;; 2) validate - business logic / enrichment
         [validated ((spec-validate spec) received instance accessors)]

         ;; 3) decide-next-state
         [next-state ((spec-decide-next-state spec) validated instance accessors)]
         [_          (assoc! accessors :next next-state)]

         ;; 4) store-ephemeral
         [staged-ephemeral ((spec-store-ephemeral spec) instance validated accessors)]

         ;; 5) store-durable (returns diff or full entity)
         [staged-durable ((spec-store-durable spec) instance validated accessors)]
         [durable-entity
           (cond
             ((and (sorted-map? staged-durable)
                   (key? staged-durable entity-key)) staged-durable) ; full entity
             ((sorted-map? staged-durable) (make-mergemap instance staged-durable)) ; diff
             (:else instance))]

          ;; 6) send - emits events
         [events ((spec-send spec) durable-entity validated accessors)]

         [entity-id-final (get durable-entity entity-key)])

    ;; persist staged ephemerals
    (when (and entity-id-final (> (length staged-ephemeral) 0))
      (ephem-persist-staged! entity-name entity-id-final next-state staged-ephemeral states))

    ;; advance durable state
    (assoc! durable-entity "state" next-state)

    ;; purge ephemerals for entered state
    (when entity-id-final
      (ephem-purge-for-state! entity-name entity-id-final next-state))

    (let* ([after-storage-hook (spec-after-storage-hook spec)]
           [events-vector (if (vector? events) events (vector))]
           [result (sorted-map
                    "put"    durable-entity
                    "events" events-vector)])
      (when after-storage-hook
        (assoc! result "after-storage-hook" after-storage-hook))
      result)))



;; ---------------- Spec builder + defaults ----------------

(defun mk-state-handler (&key receive validate decide-next-state store-ephemeral store-durable send next after-storage-hook)
  (sorted-map
    :receive           (or receive _noop-receive)
    :validate          (or validate _noop-validate)
    :decide-next-state (or decide-next-state (lambda (v e a) (or next "STATE_UNKNOWN")))
    :store-ephemeral   (or store-ephemeral _noop-store-ephemeral)
    :store-durable     (or store-durable _noop-store-durable)
    :send              (or send _noop-send)
    :after-storage-hook (or after-storage-hook false)))

;; safe defaults
(defun _noop-receive (resp entity accessors) resp)
(defun _noop-validate (received entity accessors) received)
(defun _noop-store-ephemeral (entity validated accessors) (vector))
(defun _noop-store-durable (entity validated accessors) ())
(defun _noop-send (entity validated accessors) (vector))

;; registry / lookup
(defun lookup-state-spec (state states)
  (or (get states state) (sorted-map)))

;; accessors
(defun spec-receive (spec)           (or (get spec :receive) _noop-receive))
(defun spec-validate (spec)          (or (get spec :validate) _noop-validate))
(defun spec-decide-next-state (spec) (or (get spec :decide-next-state) (lambda (v e a) "STATE_UNKNOWN")))
(defun spec-store-ephemeral (spec)   (or (get spec :store-ephemeral) _noop-store-ephemeral))
(defun spec-store-durable (spec)     (or (get spec :store-durable) _noop-store-durable))
(defun spec-send (spec)              (or (get spec :send) _noop-send))
(defun spec-after-storage-hook (spec) (or (get spec :after-storage-hook) false))

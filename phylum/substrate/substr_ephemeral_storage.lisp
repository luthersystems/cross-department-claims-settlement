(in-package 'cdcs) 

;; ---------- helpers for safe prefix handling ----------
(defun _prefix-range (prefix)
  ;; Return [start end] range for scanning a prefixed keyspace
  (vector prefix (format-string "{}\uffff" prefix)))

(defun ephem-index-key (entity-name entity-id drop-state)
  (join-index-cols "cdcs" entity-name "ephem" "index" entity-id drop-state))

;; ---------- Ephemeral bucket/router keys ----------
(defun ephem-bucket-key (entity-name entity-id drop-state)
  ;; cdcs:<entity>:ephem:bucket:<entityId>:<dropState>
  (join-index-cols "cdcs" entity-name "ephem" "bucket" entity-id drop-state))

(defun ephem-router-key (entity-name entity-id ekey)
  ;; cdcs:<entity>:ephem:router:<entityId>:<eKey>
  (join-index-cols "cdcs" entity-name "ephem" "router" entity-id ekey))

(defun ephem-router-prefix (entity-name entity-id)
  ;; prefix for scanning all router entries for an entity
  (join-index-cols "cdcs" entity-name "ephem" "router" entity-id))

;; Read by key: router -> bucket -> value
(defun ephem-get (entity-name entity-id ekey)
  (let* ([ds (sidedb:get (ephem-router-key entity-name entity-id ekey))])
    (when ds
      (let* ([bkey   (ephem-bucket-key entity-name entity-id ds)]
             [bucket (sidedb:get bkey)])
        (and bucket (get bucket ekey))))))

;; Persist a vector of intents returned by stage-ephemeral
;; Each intent: {:key <string> :value <any> [:drop-state <string>]}
(defun ephem-persist-staged! (entity-name entity-id default-drop-state intents states)
  (map ()
    (lambda (it)
      (let* ([ekey (get it :key)]
             [eval (get it :value)]
             [ds   (or (get it :drop-state) default-drop-state)]
             [bkey (ephem-bucket-key entity-name entity-id ds)]
             [bucket (or (sidedb:get bkey) (sorted-map))])

        ;; Validate the drop-state before persisting
        (validate-state-exists! ds states)

        ;; write bucket first
        (assoc! bucket ekey eval)
        (sidedb:put bkey bucket)

        ;; write router
        (sidedb:put (ephem-router-key entity-name entity-id ekey) ds)

        ;; append ekey to index list
        (let* ([ikey  (ephem-index-key entity-name entity-id ds)]
       [index (or (sidedb:get ikey) (vector))])
  (append! index ekey)            ; in-place append
  (sidedb:put ikey index))))
    intents)
  (sorted-map "ok" true))

;; Purge everything whose drop-state == <drop-state>
;;  - delete the whole bucket
;;  - clean router entries whose VALUE equals <drop-state>
(defun ephem-purge-for-state! (entity-name entity-id drop-state)
  (let* ([bkey (ephem-bucket-key entity-name entity-id drop-state)]
         [ikey (ephem-index-key entity-name entity-id drop-state)]
         [ekeys (or (sidedb:get ikey) (vector))])

    ;; purge all router entries
    (map ()
      (lambda (ek)
        (sidedb:purge (ephem-router-key entity-name entity-id ek)))
      ekeys)

    ;; purge bucket + index
    (sidedb:purge bkey)
    (sidedb:purge ikey))

  (sorted-map "ok" true))
  
  (defun validate-state-exists! (state states)
  (when (or (nil? state) (empty? (lookup-state-spec state states)))
    (set-exception-unexpected
      (format-string "invalid or missing state name: {}" state))))

;;;;;;;

(defun register-pause-callback (factory required-state entity rid)
  (let* ([rid rid]  ; the same one your webhook connector listens for
         [oid (get entity "invoice_id")]
         [rid (format-string "{}-{}" rid oid)] ; e.g. update_payment_status_<invoice_id>
         [key (mk-uuid)]
         [pdc "private"]
         [placeholder (json:dump-bytes (sorted-map "pause" true))]
         [ctx (sorted-map
                 "oid" oid
                 "key" key
                 "pdc" pdc
                 "required_state" required-state)]
         [handler-name (factory 'name)])
    ;; make cleanup deterministic
    (cc:storage-put-private pdc key placeholder)
    (connector-handlers 'register-request-callback rid handler-name ctx)
    rid))


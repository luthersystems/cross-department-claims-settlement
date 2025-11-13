(in-package 'sandbox)
(use-package 'router)
(use-package 'utils)
(use-package 'validations)

;;
;; Connector hubs (hub) listen for events that encode requests, forward them to
;; third-party services, and then send the responses back to the phylum, via
;; a special $ch_callback endpoint. Events are carefully crafted using several
;; data structures to ensure privacy and economic storage.
;;
;; *Request Generation Logic*:
;;
;; Phylum logic create events, and register a callback class factory, that
;; instantiates a business object (using the "class" pattern) which receives
;; the response using a `'handle` method. Each event registration specifies
;; the business object class that is responsible for instantiating these
;; objects, along with the "Object ID" (OID) associated with the event.
;;
;; The event header is stored in the event data map, using a special prefix
;; `$connector_events:N`, where `N` is an incrementing counter. A single
;; phylum tx may contain multiple event headers and multiple events.
;; Note that event data is public to the orderer and all members of the network.
;; The event header contains a reference to a particular event "context".
;;
;; An event has a "context", which is data that is also available to the
;; callback during its execution. The context is stored in the sideDB, a
;; hardcoded PDC with name `private`. Luther configures its networks so that
;; all orgs have access to this common PDC, however the orderer does not have
;; access to any PDC. The key for this context data is `$cr:<REQ_ID>`.
;; The context is wrapped in a "callback state" object, which includes the 
;; handler name for the object, necessary for routing responses to factories.
;; The event context contains a reference to the request body, along with an 
;; MSP that determines which org and their respective connector is responsible
;; for processing the request. The context also stores the OID, which is used
;; when processing the response.
;;
;; The request body itself is stored either in the stateDB or in a PDC, and is
;; referenced indirectly by the event context. The body contains the request
;; payload that is to be forwarded to the third-party system. Every request has
;; a unique request ID, which is used to correlate a response to a callback.
;; *IMPORTANT*: this request ID is NOT the same as the request ID embedded
;; in the transaction context, which is primarily used for tracing.
;;
;; *Response Handling Logic*:
;;
;; Once the hub has forwarded the request, and received a response from the
;; third-party system, it then sends this response to the `$ch_callback `
;; entrypoint, passing in the response as transient data using key prefix 
;; `$ch_rep:N`, which may include multiple responses for different requests.
;; This response includes the request ID, which is used to correlate the
;; response with the request via the same event context. The MSPID in the
;; original event context is used to ensure that a response is only received
;; by the correct org, so an org cannot spoof responses for requests from
;; another org.
;;
;; The phylum logic for `$ch_callback` uses the req ID to lookup the event
;; context, along with the OID and class factory. The class factory is used
;; to instantiate the object for that OID, and call the handle method on that
;; object with the response.
;;
;; Upon execution of the callback, the original event context is purged, along
;; with the original request (or deleted if in state DB), so as to reduce
;; storage space.
;;
(defun mk-connector-handler ()
  (let ([reg-handlers (sorted-map)])
    (labels
      ([register-handler (name fn)
         (assoc! reg-handlers name fn)]

       [mk-request-key (req-id)
         (format-string "$cr:{}" req-id)]

       ;; IMPORTANT: we store this in the central `private` PDC since we
       ;; don't know which PDC the original request was stored.
       [register-request-callback (req-id handler-name &optional ctx)
         (let* ([ctx (default ctx (sorted-map))]
                [callback-state (sorted-map
                               "handler_name" handler-name)])
           (assoc! ctx "request_id" req-id)
           (assoc! callback-state "ctx" ctx)
           (sidedb:put (mk-request-key req-id) callback-state))]

       [unregister-request (req-id ctx)
         ;; TODO: handle multiple responses for single request_id (optional) 
         (let* ([callback-state-key (mk-request-key req-id)]
                [key (get ctx "key")]
                [pdc (get ctx "pdc")])
           (sidedb:purge callback-state-key)
           (if pdc
            (cc:storage-purge-private pdc key)
            (statedb:del key)))]

       [get-callback-state (req-id)
         (or (sidedb:get (mk-request-key req-id))
                         (error 'missing-callback-state
                                (format-string "no callback state {}" req-id)))]

       [invoke-handler-helper (resp-body)
         (unless resp-body (error 'missing-resp "missing response"))
         (let* ([req-id (get resp-body "request_id")]
                [callback-state (get-callback-state req-id)]
                [handler-name (get callback-state "handler_name")]
                [ctx (default (get callback-state "ctx") (sorted-map))]
                [msp (get ctx "msp")]
                [system-name (get ctx "sys")]
                [handler-fn (get reg-handlers handler-name)])
           (cc:infof (sorted-map
                       "request_id" req-id
                       "system" system-name
                       "handler" handler-name
                       "entity_id" (get ctx "oid"))
                     "Response received from ConnectorHub")
           (when msp 
             (unless (valid-msp? msp)
               (set-exception-security "invalid MSP for response")))
               
           (if handler-fn
             (handler-fn resp-body ctx)
             (error 'missing-handler 
                    (format-string "missing connector handler: {}" handler-name)))
           (unregister-request req-id ctx))]

       [invoke-handler-helper-recurse-i (i)
         (let* ([resp-body (transient:get (format-string "$ch_rep:{}" i))])
           (when resp-body
             (handler-bind
               ([missing-callback-state
                 (lambda (&rest xs)
                   (cc:warnf (sorted-map "$ch_rep" i "error" xs) "no callback state"))])
               (invoke-handler-helper resp-body))
             (invoke-handler-helper-recurse-i (+ i 1))))]

       [invoke-handler (resp)
         (invoke-handler-helper-recurse-i 0)])
 
    (lambda (op &rest args)
        (cond ((equal? op 'register-handler) (apply register-handler args))
              ((equal? op 'register-request-callback) (apply
                                                        register-request-callback
                                                        args))
              ((equal? op 'invoke-handler) (apply invoke-handler args))
              ((equal? op 'invoke-handler-with-body) (apply invoke-handler-helper args))
              ((equal? op 'get-callback-state) (apply get-callback-state args))
              (:else (error 'unknown-operation op)))))))


(export 'connector-handlers)
(set 'connector-handlers (singleton mk-connector-handler))

;; internal handler called by the connector hub
(defendpointnames "$ch_callback" '("resp") (resp)
  ;; the response is passed as transient data
  (connector-handlers 'invoke-handler resp)
  (route-success (sorted-map "status" "OK")))

(export 'connector-events)
(defun mk-connector-events ()
  (let ([state (sorted-map)])
    (labels
      ([num-events () (default (get state "ctr") 0)]
       [inc-events () (assoc! state "ctr" (+ (num-events) 1))]
       [mk-event-ref-key (ctr) (format-string "$connector_events:{}" ctr)]
       [reset ()
              "reset cleares the pending connector events"
              (map ()
                   (lambda (i) (cc:set-tx-metadata (mk-event-ref-key i) ()))
                   (make-sequence 0 (num-events)))
              (set! state (sorted-map))]
       [raise
         (event &optional handler-name)
         "raise inspects an event and sets up the data structures to register callbacks."
         (let*
           ([ctr (num-events)]
            [event-body (get event "req")]
            [event-req-id (mk-uuid)]
            [event-key (or (get event "key") event-req-id)]
            [event-pdc (get event "pdc")] ; pdc storing key with req
            [event-oid (get event "oid")] ; object to receive event
            [event-header (sorted-map "rid" event-req-id)]
            [ctx (sorted-map "oid" event-oid
                             "key" event-key
                             "pdc" event-pdc
                             "msp" (get event "msp")   ; opt. connector MSP
                             "sys" (get event "sys")   ; opt. system name
                             "eng" (get event "eng"))] ; opt. english event
            [ctx (denil-map ctx)]
            [event-ref-str
              (thread-first
                event-header
                (denil-map)
                (json:dump-bytes)
                (to-string))]
            [event-ref-key (mk-event-ref-key ctr)]
            [event-body-bytes (json:dump-bytes event-body)])
           (when (>= ctr 10) (error 'too-many-events "too many events"))
           (when handler-name
             (connector-handlers
               'register-request-callback 
               event-req-id
               handler-name 
               ctx))
           (cc:set-tx-metadata event-ref-key event-ref-str)
           (if event-pdc
             (cc:storage-put-private event-pdc 
                                     event-key
                                     event-body-bytes)
             (cc:storage-put event-key event-body-bytes))
           (cc:infof (sorted-map
                       "system" (get event "sys")
                       "action" (get event "eng")
                       "request_id" event-req-id
                       "entity_id" (get event "oid"))
                     "Event sent to ConnectorHub")
           (inc-events))])
      (lambda (op &rest args)
        (cond ((equal? op 'raise) (apply raise args)) 
              ((equal? op 'reset) (apply reset args))
              (:else (error 'unknown-operation op)))))))

(set 'connector-events (singleton mk-connector-events))

(defun do-transition (obj-factory transition)
  (let* ([obj-handler-name (or (obj-factory 'name)
                             (error 'missing-name "factory missing name"))]
         [put-obj (get transition "put")]
         [del-obj (get transition "del")]
         [events (get transition "events")])
    (when put-obj
      (obj-factory 'put put-obj))
    (when del-obj
      (obj-factory 'del obj-id))
    (map () #^(connector-events 'raise % obj-handler-name) events)
    put-obj))

(export 'new-connector-object)
(defun new-connector-object (obj-factory)
  (do-transition obj-factory (obj-factory 'new)))

(export 'trigger-connector-object)
(defun trigger-connector-object (obj-factory obj-id resp &optional ctx)
  (let* ([obj-id (or obj-id
                     (error 'missing-obj-id "callback missing object ID"))]
         [obj (or (obj-factory 'get obj-id)
                  (error 'missing-obj "callback missing object"))]
         [transition (obj 'handle resp ctx)])
    (do-transition obj-factory transition)))

;; Register a connector factory (entity manager) with the callback handler system.
;;
;; This function:
;; 1. Gets the handler name from the factory (e.g., "claim" from claim-manager-wf2)
;; 2. Registers a closure in the global connector-handlers registry
;; 3. The closure captures the obj-factory, allowing it to route callbacks to the
;;    correct manager even when multiple factories share the same handler name
;;
;; When a callback arrives:
;; - The connector hub calls $ch_callback with a request_id
;; - invoke-handler-helper looks up the handler by handler_name from the callback state
;; - The closure is invoked with (resp ctx), which then calls trigger-connector-object
;;   with the captured obj-factory
;;
;; This closure pattern allows multiple workflows (e.g., claim-manager-wf2 and
;; claim-manager-wf3) to both register handlers named "claim" - each closure
;; captures its own factory reference, so callbacks route to the correct manager.
(export 'register-connector-factory)
(defun register-connector-factory
  (obj-factory)
  (let ([obj-handler-name (or (obj-factory 'name)
                              (error 'missing-name "factory missing name"))])
    (connector-handlers
      'register-handler
      obj-handler-name
      (lambda (resp ctx) (trigger-connector-object obj-factory
                                                   (get ctx "oid") resp ctx)))))

;;
;; Helper functions to raise events that contain requests destined for specific
;; 3rd-party systems via the connectorhub.
;; TODO: use user-defined types for type checking
;;

(export 'mk-email-req)
(defun mk-email-req (recipient title body)
  "Create a request to send an email."
  (let* ([m (sorted-map "recipient" (to-string recipient)
                        "title" (to-string title)
                        "body" (to-string body))]) 
    (validate-nonempty-string m "recipient") 
    (validate-nonempty-string m "title") 
    (validate-nonempty-string m "body") 
    (sorted-map "email" m)))

(defun mk-metadata (m)
  (let* ([new-meta (sorted-map)])
    (when m
      (map ()
           (lambda (k) (assoc! new-meta (to-string k) (to-string (get m k))))
           (keys m)))
    new-meta))

(export 'mk-gocardless-req)
(defun mk-gocardless-req (details) 
  "Create a request to trigger a GoCardless payment against a mandate."
  (let* ([payment 
           (sorted-map 
             "amount" (to-int (default (get details "amount") 0))
             "app_fee" (to-int (default (get details "app_fee") 0))
             "charge_date" (to-string (default (get details "charge_date") "")) 
             "currency" (to-string (default (get details "currency") "USD"))
             "faster_ach" (true? (default (get details "faster_ach") false))
             "mandate_link" (to-string (default (get details "mandate_link") ""))
             "metadata" (mk-metadata (default (get details "metadata") (sorted-map)))
             "reference" (to-string (default (get details "reference") ""))
             "retry_if_possible" (true? (default (get details "retry_if_possible") false)))]) 
    (sorted-map "gocardless" (sorted-map "payment" payment))))

(defun encode-camunda-vars (var-map)
  (unless (empty? var-map)
    (hex:encode (json:dump-bytes var-map))))

(export 'mk-camunda-start-req)
(defun mk-camunda-start-req (pdk &optional vars-map)
  "Trigger a Camunda workflow given a process definition key, optional business key, and sorted-map of vars."
  (let* ([vars-map (default vars-map (sorted-map))]
         [m (sorted-map
              "process_definition_key" (when pdk (to-string pdk))
              "business_key" (get vars-map "business_key")
              "variables" (encode-camunda-vars vars-map))])
    (validate-nonempty-string m "process_definition_key")
    (sorted-map "camunda_start" m)))

(export 'mk-camunda-inspect-req)
(defun mk-camunda-inspect-req (pid &optional wait-for-state)
  "Inspect a Camunda workflow given a process instance ID."
  (let* ([m (sorted-map
              "process_instance_id" (to-string pid)
              "wait_for_state" (when wait-for-state (to-string wait-for-state)))])
    (validate-nonempty-string m "process_instance_id")
    (sorted-map "camunda_inspect" m)))

(defun to-string-or-nil (str)
  (when str (to-string str)))

(export 'mk-equifax-req)
(defun mk-equifax-req (details)
  "Execute a identity verification check against Equifax for a person."
  (validate-nonempty-string details "forename")
  (validate-nonempty-string details "surname")
  (validate-nonempty-string details "dob")
  (let* ([m (sorted-map
              "account_number" (to-string-or-nil (get details "account_number"))
              "account_sort_code" (to-string-or-nil (get details "account_sort_code"))
              "dob" (to-string-or-nil (get details "dob"))
              "middle_name" (to-string-or-nil (get details "middle_name"))
              "surname" (to-string-or-nil (get details "surname"))
              "forename" (to-string-or-nil (get details "forename"))
              "address_name" (to-string-or-nil (get details "address_name"))
              "address_number" (to-string-or-nil (get details "address_number"))
              "address_street1" (to-string-or-nil (get details "address_street1"))
              "address_street2" (to-string-or-nil (get details "address_street2"))
              "address_postcode" (to-string-or-nil (get details "address_postcode"))
              "address_post_town" (to-string-or-nil (get details "address_post_town"))
              "previous_address_name" (to-string-or-nil (get details "previous_address_name"))
              "previous_address_number" (to-string-or-nil (get details "previous_address_number"))
              "previous_address_street1" (to-string-or-nil (get details "previous_address_street1"))
              "previous_address_street2" (to-string-or-nil (get details "previous_address_street2"))
              "previous_address_postcode" (to-string-or-nil (get details "previous_address_postcode"))
              "previous_address_post_town" (to-string-or-nil (get details "previous_address_post_town")) 
              "nationality" (to-string-or-nil (get details "nationality")))]
         [d (sorted-map "client_details" m)])
    (sorted-map "equifax" d)))

(defun mk-psql-clazz (m)
  (let* ([classmap (sorted-map
                     "POSTGRES_CLAZZ_NULL"           "POSTGRES_CLAZZ_NULL"
                     "POSTGRES_CLAZZ_BOOLEAN"        "POSTGRES_CLAZZ_BOOLEAN"
                     "POSTGRES_CLAZZ_INTEGRAL"       "POSTGRES_CLAZZ_INTEGRAL"
                     "POSTGRES_CLAZZ_FLOATING_POINT" "POSTGRES_CLAZZ_FLOATING_POINT"
                     "POSTGRES_CLAZZ_TEXT"           "POSTGRES_CLAZZ_TEXT"
                     "POSTGRES_CLAZZ_BLOB"           "POSTGRES_CLAZZ_BLOB")])
    (validate-nonempty-string classmap m)
    (get classmap m)))

(defun mk-psql-args (tuples)
  (map 'vector 
       (lambda (x)
         (validate-nonempty-string x "clazz")
         (validate-nonempty-string x "representation")
         (sorted-map
           "clazz" (mk-psql-clazz (get x "clazz"))
           "representation" x))
       tuples))

(export 'mk-psql-req)
(defun mk-psql-req (query &optional args metadata)
  "Execute a postgres query."
  (let* ([m (sorted-map
              "query" query
              "arguments" (mk-psql-args args)
              "metadata" (mk-metadata metadata))])
    (validate-nonempty-string m "query")
    (sorted-map "postgres" m)))

(export 'mk-pdfserv-req)
(defun mk-pdfserv-req (html)
  "Generate a PDF from HTML."
  (let* ([m (sorted-map
              "html_base64" (to-string (base64:encode html)))])
    (validate-nonempty-string m "html_base64")
    (sorted-map "pdfserv" m)))


(export 'mk-stripe-charge-req)
(defun mk-stripe-charge-req (req)
  "Create a request to initiate a Stripe charge."
  (validate-nonempty-string req "customer_id")
  (validate-positive-int   req "amount")
  (validate-nonempty-string req "currency")
  (validate-nonempty-string req "source_id")
  (let* ([charge
           (sorted-map
             "customer_id" (get req "customer_id")
             "amount"      (get req "amount")
             "currency"    (get req "currency")
             "source_id"   (get req "source_id")
             "description" (default (get req "description") ""))])
    (sorted-map
      "stripe"
      (sorted-map "create_charge_request" charge))))

(export 'mk-invoice-ninja-email-req)
(defun mk-invoice-ninja-email-req (req)
  "Create a request to initiate an Invoice Ninja email."
  (validate-nonempty-string req "invoice_id")
  (let* ([email-req
           (sorted-map
             "invoice_id" (get req "invoice_id"))])
    (sorted-map
      "invoice_ninja"
      (sorted-map "create_email_request" email-req))))

(export 'mk-fetch-req)
(defun mk-fetch-req (req)
  "Create a request to fetch a URL and return markdown contents."
  ;; make sure required fields are present
  (validate-nonempty-string req "url")
  ;; build up the arguments map, with sensible defaults
  (let* ([args (sorted-map
                 "url"         (get req "url")
                 "max_length"  (default (get req "max_length") 5000)
                 "raw"         (default (get req "raw") false)
                 "start_index" (default (get req "start_index") 0))])
    ;; wrap it in the generic envelope
    (sorted-map
      "generic"
      (sorted-map
        "kind"       "KIND_FETCH"
        "operation"  "fetch"
        "arguments"  args))))

(export 'mk-connector-req)
(defun mk-connector-req (req)
  "Create a generic request to the connector hub, with limited validation."
  (validate-nonempty-string req "kind")
  (validate-nonempty-string req "operation")
  (validate-not-nil req "args")
  (sorted-map
    "generic"
    (sorted-map
      "kind"       (get req "kind")
      "operation"  (get req "operation")
      "arguments"  (get req "args"))))

(export 'mk-connector-resp)
(defun mk-connector-resp (resp)
  "Unpack a generic response from the connector hub, with limited validation."
  (validate-not-nil resp "generic")
  (let* ([raw (get resp "generic")]) 
    (validate-nonempty-string raw "text")
    (sorted-map "raw_resp" raw)))

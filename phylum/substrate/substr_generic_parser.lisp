(in-package 'cdcs)
; 

;; ---------------- Convenience: generic parser helper ----------------

;; Build a connector event from entity, request, action, and system name
(defun build-event (entity req action sys-name entity-id)
  (let* ([oid entity-id]
         [result (sorted-map
                   "oid" oid
                   "key" (mk-uuid)
                   "pdc" "private"
                   "msp" "Org1MSP"
                   "sys" sys-name
                   "eng" action
                   "req" req)])
    (when (nil? entity-id)
      (cc:warnf (sorted-map
                  "action" action
                  "sys_name" sys-name
                  "has_entity_id" false)
                "build-event: entity-id is nil, oid will be nil"))
    (cc:infof (sorted-map
                "action" action
                "sys_name" sys-name
                "entity_id" entity-id
                "oid" oid)
              "build-event: creating event")
    result))

;; ---------------- Helper: Get from resp or entity ----------------

;; Get a value from resp (explicit request) or entity (accumulated data), with optional default.
;; Priority: resp > entity > default
;; This abstracts the common pattern used in init handlers to support both:
;;   - Route invocations (data in resp)
;;   - Unified process transitions (data in entity, resp is empty)
(export 'get-from-resp-or-entity)
(defun get-from-resp-or-entity (key resp entity &optional default)
  (or (get resp key) (get entity key) default))

;; ---------------- Helper: Boolean normalization ----------------

;; Best-effort boolean coercion with sensible defaults.
;; Handles strings ("true", "false", "1", "0", "yes", "no", etc.), booleans, and nil.
(export 'normalize-bool)
(defun normalize-bool (value &optional default-value)
  (cond
    ((nil? value) (if (nil? default-value) false default-value))
    ((equal? value true) true)
    ((equal? value false) false)
    ((string? value)
     (let* ([lower (string:downcase value)])
       (cond
         ((or (equal? lower "true")
              (equal? lower "1")
              (equal? lower "yes")
              (equal? lower "y")
              (equal? lower "on")) true)
         ((or (equal? lower "false")
              (equal? lower "0")
              (equal? lower "no")
              (equal? lower "n")
              (equal? lower "off")) false)
         (:else (if (nil? default-value) false default-value)))))
    (:else (if (nil? default-value) false default-value))))

(defun parse-generic-resp (resp &key skip-inner-error-check)
  (let* ([resp-body (get resp "response")]
         [resp-err  (get resp "error")])
    (when resp-err
      (set-exception-unexpected
        (format-string "unhandled response error: {}" resp-err)))
    (let* ([container (and resp-body (get resp-body "generic"))]
           [text-json (and container (get container "text"))]
           [parsed    (and text-json (json:load-string text-json))])
      (when (and (not skip-inner-error-check) (sorted-map? parsed))
        (let ([inner-error (get parsed "error")])
          (when inner-error
            (set-exception-unexpected
              (format-string "connector inner error: {}" inner-error)))))
      parsed)))

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
           [parsed    (cond
                        (text-json (json:load-string text-json))
                        (resp-body resp-body)
                        (:else (sorted-map)))])
      (when (and (not skip-inner-error-check) (sorted-map? parsed))
        (let ([inner-error (get parsed "error")])
          (when inner-error
            (set-exception-unexpected
              (format-string "connector inner error: {}" inner-error)))))
      parsed)))

;; ---------------- SQL string literals ----------------

;; The database connectors take raw SQL text and have no bind parameters, so
;; a value that goes into a query must be written as a quoted literal that
;; its content cannot end early.  These helpers exist so that no event
;; builder interpolates a value between bare quotes.

;; Quote a value as a standard SQL string literal (Oracle, SAP HANA): wrap it
;; in single quotes and double each quote inside it.  These databases treat a
;; backslash as an ordinary character, so it is left as is.
;; A nil value is written as NULL, not as the text "()", so a missing value
;; never turns into stored data.
(export 'sql-quote)
(defun sql-quote (value)
  (if (nil? value)
    "NULL"
    (format-string "'{}'" (string:join (string:split (to-string value) "'") "''"))))

;; Quote a value as a MySQL string literal.  MySQL also reads a backslash as
;; an escape, so `\'` would undo the doubled quote; doubling each backslash
;; first keeps the literal closed.  A server with NO_BACKSLASH_ESCAPES would
;; then read a backslash in the value as two; that only makes a lookup miss,
;; while the opposite choice would let a value end the literal.
(export 'sql-quote-mysql)
(defun sql-quote-mysql (value)
  ;; Raw strings: this elps version's lexer misreads "\\" before a paren.
  (if (nil? value)
    "NULL"
    (sql-quote (string:join (string:split (to-string value) """\""") """\\"""))))

;; Write a number for a SQL statement as a plain decimal literal.  The value
;; is spliced in without quotes, so only text that is all digits (with an
;; optional sign and fraction) is allowed.  A decimal string such as
;; "2500.00" is accepted because JSON clients often send money that way.  A
;; float is written as elps prints it, but elps prints large or very precise
;; floats in exponent form (2.5000005e+06), which a database reads as an
;; approximate DOUBLE; that form, NaN and Inf are refused, and the caller
;; should send such an amount as a decimal string.
(set 'sql--decimal-re (regexp:regexp-compile "^-?[0-9]+([.][0-9]+)?$"))

(export 'sql-number)
(defun sql-number (value)
  (let* ([text (cond ((int? value) (to-string value))
                     ((and (float? value) (= value (to-float (to-int value))))
                      (to-string (to-int value)))
                     ((float? value) (to-string value))
                     ((string? value) value)
                     (:else ""))])
    (unless (regexp:regexp-match? sql--decimal-re text)
      (set-exception-business (format-string "not a plain decimal number: {}" value)))
    text))

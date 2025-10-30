;; camunda_transitions.lisp
;; ------------------------
;; Defines high-level transition builders for Camunda connector.
;; Uses mk-camunda-start-req and wraps into standard transition events
;; via build-camunda-event (from invoice_transition.lisp).

(in-package 'sandbox)

; (use-package 'connector)

(defun mk-httpwebhook-register-transition (invoice path &optional opts)
  (build-httpwebhook-event
    invoice
    (mk-httpwebhook-register-req path opts)
    "register webhook"))

    (export 'mk-httpwebhook-register-req)

(defun mk-httpwebhook-register-req (path &optional opts)
  (let* ([opts (default opts (sorted-map))]
         [m (sorted-map
              "path"             (to-string path)
              "id"               (get opts "id")
              "secret"           (get opts "secret")
              "signature_header" (get opts "signature_header")
              "allow_unsigned"   (get opts "allow_unsigned")
              "forward_raw"      (get opts "forward_raw")
              "max_body_bytes"   (get opts "max_body_bytes"))])
    (validate-nonempty-string m "path")
    (sorted-map
      "http_webhook"
      (sorted-map "register_request" m))))

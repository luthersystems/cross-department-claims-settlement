(in-package 'sandbox)
; (use-package 'connector)

;; Build the http_webhook_create envelope with a register_request
  ; "opts is a map with optional keys:
  ;    request_id_token
  ;    request_id_field_in_payload
  ;    callback_url_field_in_payload
  ;    headers                 ; map<string,string>
  ;    timeout_ms              ; integer
  ; payload is a flat/nested map (will be sent as JSON by the connector)."
(defun mk-httpwebhook-create-req (request-id target-url callback-url-template payload &optional opts)
  (let* ([req (sorted-map
                "request_id"                   request-id
                "target_url"                   target-url
                "payload"                      payload
                "callback_url_template"        callback-url-template)]
         ;; Copy optionals if present
         [req (if (and opts (get opts "request_id_token"))
                (assoc! req "request_id_token" (get opts "request_id_token")) req)]
         [req (if (and opts (get opts "request_id_field_in_payload"))
                (assoc! req "request_id_field_in_payload" (get opts "request_id_field_in_payload")) req)]
         [req (if (and opts (get opts "callback_url_field_in_payload"))
                (assoc! req "callback_url_field_in_payload" (get opts "callback_url_field_in_payload")) req)]
         [req (if (and opts (get opts "headers"))
                (assoc! req "headers" (get opts "headers")) req)]
         [req (if (and opts (get opts "timeout_ms"))
                (assoc! req "timeout_ms" (get opts "timeout_ms")) req)])
    ;; Envelope: { http_webhook_create: { register_request: <req> } }
    (sorted-map
      "http_webhook_create"
      (sorted-map "register_request" req))))

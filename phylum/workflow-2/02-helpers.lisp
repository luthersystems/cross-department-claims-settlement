;;; guidewire

(defun mk-guidewire-get-claim-event (entity claim-id)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind" "KIND_OUTBOUND_REST"
                  "operation" "getClaimDetails"     
                  "args" (sorted-map "claim_id" claim-id)))])
    (build-event entity req "get claim" "OUTBOUNDGW")))

(defun parse-guidewire-claim (resp)
  (if (nil? resp)
      (set-exception-business "missing Guidewire claim response")
      (sorted-map
        "claim_id" (get resp "claim_id")
        "policy_id" (get resp "policy_id")
        "status" (get resp "status")
        "handler" (get resp "handler"))))

;;; mysql

(defun mk-mysql-check-policy-event (entity args)
  (let* ([sql (format-string
                "SELECT POLICY_ID, STATUS, COVERAGE_LIMIT FROM policies WHERE POLICY_ID='{}' AND STATUS='Active' LIMIT 1"
                (get args "policy_id"))]
         [req (mk-connector-req
                (sorted-map
                  "kind" "KIND_MYSQL"
                  "operation" "mysql_query"
                  "args" (sorted-map "sql" sql)))])
    (build-event entity req "check policy" "MYSQL")))

(defun parse-mysql-policy (resp)
  "Parse MySQL MCP response for policy status and coverage."
  (let* ([row (if (and (vector? resp) (> (length resp) 0))
                  (first resp)
                  (set-exception-business "MySQL returned no rows"))])
    (sorted-map
      "policy_id"      (get row "POLICY_ID")
      "status"         (get row "STATUS")
      "coverage_limit" (get row "COVERAGE_LIMIT"))))

;; sharepoint
(defun mk-sharepoint-get-id-doc-event (entity args)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind"      "KIND_MICROSOFT_SHAREPOINT"
                  "operation" "get_document_content"
                  "args" (sorted-map
                            "site_id"  (get args "site_id")
                            "drive_id" (get args "drive_id")
                            "item_id"  (get args "item_id")
                            "filename" (get args "filename"))))])
    (build-event entity req "get id-verification content" "SHAREPOINT")))


(defun parse-sharepoint-docs (resp)
  (let* ([docs (get resp "documents")])
    (sorted-map
      "documents"
        (map 'vector
             (lambda (d)
               (sorted-map
                 "type" (get d "type")
                 "file" (get d "file")))
             docs))))


;;;; guidewire (end)

(defun mk-guidewire-approval-update-event (entity args)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind" "KIND_OUTBOUND_REST"
                  "operation" "updateClaimApproval"
                  "args" (sorted-map
                            "claimId"    (get args "claim_id")
                            "approval"   (get args "approval")
                            "approvedBy" (get args "approved_by"))))])
    (build-event entity req "update approval" "OUTBOUNDGW")))

(defun parse-guidewire-approval-update (resp)
  (sorted-map
    "approval_status" (get resp "status")
    "confirmation"    (get resp "message")))

;; =============================
;; 9) DONE (terminal state)
;; =============================
(defun wf2-claim-done-state-handler (&optional next-state)
  (labels
    ([parse (resp entity) (parse-generic-resp resp)]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors) ()]
     [create-events (entity parsed accessors) ()])
    (mk-state-handler
      :next            (or next-state "WF2_CLAIM_STATE_DONE")
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events
      :immediate-next  (if next-state true false)
      :terminal        (not next-state))))

;; build-event moved to substr_generic_parser.lisp

    

  ; "Parses the SharePoint get_document_content response via parse-generic-resp.
  ;  Validates that decoded text mentions the claim_id and (if provided) signer_name.
  ;  Extracts a Date: YYYY-MM-DD. Returns durable fields."
(defun parse-sharepoint-id-verification (resp entity)

  (let* ([parsed   (parse-generic-resp resp)]          ; unwrap inner JSON from generic.text
         [ctype    (get parsed "type")]
         [lines    (or (get parsed "content") (vector))]
         ;; decode each base64 line to text, then join with newlines
         [decoded-lines (map 'vector (lambda (s) (base64:decode s)) lines)]
         [text     (string-join decoded-lines "\n")]
         [claim-id (get entity "claim_id")]
         [signer   (get entity "signer_name")])
    (when (not (= ctype "text"))
      (set-exception-business (format-string "unexpected content type: {}" ctype)))

    (when (or (nil? text) (string-empty? text))
      (set-exception-business "empty id-verification content"))

    (let* ([claim-ok  (and claim-id (string-contains? text claim-id))]
           [signed-ok (or (nil? signer) (string-contains? text signer))])
          ;  [date-m    (regex:find #/Date:\s*(\d{4}-\d{2}-\d{2})/ text)]
          ;  [date-val  (and date-m (get date-m 1))])

      (when (not claim-ok)
        (set-exception-business "id-verification does not reference this claim_id"))

      (when (and signer (not signed-ok))
        (set-exception-business "id-verification not signed by expected signer"))

      ;; Include useful metrics if present; fall back safely
      (sorted-map
        "id_verification_ok"    true
        ; "id_verification_date"  date-val
        "id_verification_text"  text
        "id_verification_lines" (or (get parsed "line_count") (length lines))
        "id_verification_words" (get parsed "word_count")
        "id_verification_chars" (get parsed "character_count")))))
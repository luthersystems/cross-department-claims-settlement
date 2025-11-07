(defun claim-2-init-state-handler ()
  (labels
    ([parse (resp entity)
      ;; resp can be empty; we drive off entity.claim_id/policy_id
      (let* ([claim-id  (or (get entity "claim_id")  (get resp "guidewire_claim_id"))]
             [policy-id (or (get entity "policy_id") (get resp "policy_id"))])
        (sorted-map
          "guidewire_claim_id"  claim-id
          "policy_id" policy-id))]

     [stage-ephemeral (entity parsed accessors) ()]

     [stage-durable (entity parsed accessors)
      (sorted-map
        "guidewire_claim_id"  (get parsed "claim_id")
        "policy_id"           (get parsed "policy_id"))]

     [create-events (entity parsed accessors)
      (vector (mk-guidewire-get-claim-event entity (get parsed "guidewire_claim_id")))])

    (mk-state-handler
      :next            "CLAIM_STATE_GUIDEWIRE_SNAPSHOTTED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))

;; =============================
;; 5) GUIDEWIRE_SNAPSHOTTED -> MYSQL_VALIDATED
;; MySQL policy check (may run in parallel with SharePoint docs fetch)
;; =============================
(defun claim-guidewire-snapshotted-state-handler ()
  (labels
    ([parse (resp entity) (parse-guidewire-claim (parse-generic-resp resp))] ; create
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (cc:infof (sorted-map "status" (get parsed "status")) "guidewire parsed status in durable")
      (sorted-map "guidewire_status" (get parsed "status"))]
     [create-events (entity parsed accessors)
      (vector (mk-mysql-check-policy-event entity ; create
                (sorted-map "policy_id" (get entity "policy_id")
                            "claim_id"  (get entity "claim_id"))))])
  (mk-state-handler
    :next            "CLAIM_STATE_MYSQL_VALIDATED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 6) MYSQL_VALIDATED -> SP_DOCS_COLLECTED
;; SharePoint: collect supporting docs
;; =============================
(defun claim-mysql-validated-state-handler ()
  (labels
    ([parse (resp entity) 
      (cc:infof (sorted-map "resp" resp) "parse mysql resp")
        (parse-mysql-policy (parse-generic-resp resp))
      ] ; create
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "policy_status"  (get parsed "status")
        "coverage_limit" (get parsed "coverage_limit"))]
     [create-events (entity parsed accessors)
  (vector
    (mk-sharepoint-get-id-doc-event
      entity
      (sorted-map
        "site_id"  "samwoodluthersystems.sharepoint.com,af554837-6d2d-48e7-aa08-9584e15df76e,28227d76-23e6-4218-85c5-0473c0006245"
        "drive_id" "b!N0hVry1t50iqCJWE4V33bnZ9IijmIxhChcUEc8AAYkU0cfiPk4MZRaBijb338Qw8"
        "item_id"  "01RAAXWAZH6LCSA5FLHRE2QJXBSIVDOGV4"
        "filename" "id-verification.txt")))])
  (mk-state-handler
    :next            "CLAIM_STATE_SP_DOCS_COLLECTED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))


;; =============================
;; 7) SP_DOCS_COLLECTED -> GUIDEWIRE_APPROVED
;; Update/sync approval in Guidewire
;; =============================
(defun claim-sp-docs-collected-state-handler ()
  (labels
    ([parse (resp entity) (parse-sharepoint-docs resp)] ; create
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors) (sorted-map "sp_docs" (get parsed "documents"))]
     [create-events (entity parsed accessors)
        (vector (mk-guidewire-approval-update-event entity  ; create
                 (sorted-map "claim_id" (get entity "claim_id")
                             "approval" "approved"
                             "approved_by" (get entity "handler"))))] )
  (mk-state-handler
    :next            "CLAIM_STATE_GUIDEWIRE_APPROVED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))

;;;; guidewire (start)

(defun mk-guidewire-get-claim-event (entity claim-id)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind" "KIND_OUTBOUND_REST"
                  "operation" "getClaimDetails"     ; matches operationId from OpenAPI spec
                  "args" (sorted-map "claim_id" claim-id)))])
    (build-event entity req "get claim" "OUTBOUNDGW")))

(defun parse-guidewire-claim (resp)
  (cc:infof (sorted-map "resp" resp) "guidewire claim resp")
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
  (cc:infof (sorted-map "resp" resp) "resp in parse-mysql-policy")
  (let* ([row (if (and (vector? resp) (> (length resp) 0))
                  (first resp)
                  (set-exception-business "MySQL returned no rows"))])
    (cc:infof (sorted-map "row" row) "row in parse-mysql-policy")
    (sorted-map
      "policy_id"      (get row "POLICY_ID")
      "status"         (get row "STATUS")
      "coverage_limit" (get row "COVERAGE_LIMIT"))))

;; sharepoint
;;; SharePoint: build event to fetch a specific document's content
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

(defun build-event (entity req action sys-name)
  (cc:infof (sorted-map "event" (sorted-map
    "oid" (get entity "claim_id")
    "key" (mk-uuid)
    "pdc" "private"
    "msp" "Org1MSP"
    "sys" sys-name
    "eng" action
    "req" req)) "event for {}" sys-name)
  (sorted-map
    "oid" (get entity "claim_id")
    "key" (mk-uuid)
    "pdc" "private"
    "msp" "Org1MSP"
    "sys" sys-name
    "eng" action
    "req" req))

    

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

    (cc:infof (sorted-map "parsed" parsed) "parse1" )
          (cc:infof (sorted-map "ctype" ctype) "parse2" )
                (cc:infof (sorted-map "lines" lines) "parse3" )
                      (cc:infof (sorted-map "decoded-lines" decoded-lines) "parse4" )
                      (cc:infof (sorted-map "text" text) "parse5" )
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
(defun claim-2-init-state-handler ()
  (labels
    ([parse (resp entity)
      ;; resp can be empty; we drive off entity.claim_id/policy_id
      (let* ([claim-id  (or (get entity "claim_id")  (get resp "claim_id"))]
             [policy-id (or (get entity "policy_id") (get resp "policy_id"))])
        (validate-nonempty! claim-id policy-id) ; check
        (sorted-map
          "claim_id"  claim-id
          "policy_id" policy-id))]

     [stage-ephemeral (entity parsed accessors) ()]

     [stage-durable (entity parsed accessors)
      (sorted-map
        "claim_id"  (get parsed "claim_id")
        "policy_id" (get parsed "policy_id"))]

     [create-events (entity parsed accessors)
      (vector (mk-oracle-get-claim-event entity (get parsed "claim_id")))])

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
    ([parse (resp entity) (parse-guidewire-claim resp)] ; create
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
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
    ([parse (resp entity) (parse-mysql-policy resp)] ; create
     [stage-ephemeral (entity parsed accessors) ()]
     [stage-durable (entity parsed accessors)
      (sorted-map
        "policy_status"  (get parsed "status")
        "coverage_limit" (get parsed "coverage_limit"))]
     [create-events (entity parsed accessors)
      (vector (mk-sharepoint-list-docs-event entity ; create
                (sorted-map "claim_id" (get entity "claim_id")
                            "folder"   (format-string "Claims/%s/%s"
                                              (year-now) (get entity "claim_id")))))])
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
     [stage-durable (entity parsed accessors)
      (sorted-map "sp_docs" (map #(get % "type") (get parsed "documents")))]
     [create-events (entity parsed accessors)
      (let* ([approval (decide-approval entity)]) ; create
        (vector (mk-guidewire-approval-update-event entity  ; create
                 (sorted-map "claim_id" (get entity "claim_id")
                             "approval" approval
                             "approved_by" (get entity "handler")))))] )
  (mk-state-handler
    :next            "CLAIM_STATE_GUIDEWIRE_APPROVED"
    :parse           parse
    :stage-ephemeral stage-ephemeral
    :stage-durable   stage-durable
    :create-events   create-events)))

;;;; guidewire

(defun mk-guidewire-get-claim-event (entity claim-id)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind" "KIND_OUTBOUND_REST"
                  "operation" "getClaimById"
                  "args" (sorted-map "claimId" claim-id)))])
    (build-event entity req "get claim" "Guidewire")))

(defun parse-guidewire-claim (resp)
  (let* ([claim (or (get resp "claim")
                    (set-exception-business "missing Guidewire claim"))])
    (sorted-map
      "claim_id" (get claim "claim_id")
      "policy_id" (get claim "policy_id")
      "status" (get claim "status")
      "handler" (get claim "handler"))))

; store 
(sorted-map
  "guidewire_status" (get parsed "status")
  "handler"          (get parsed "handler"))



;;; mysql

(defun mk-mysql-check-policy-event (entity args)
  (let* ([sql (format-string
                "SELECT POLICY_ID, STATUS, COVERAGE_LIMIT \
                 FROM POLICIES WHERE POLICY_ID='{}' AND STATUS='Active' LIMIT 1"
                (get args "policy_id"))]
         [req (mk-connector-req
                (sorted-map
                  "kind" "KIND_MYSQL"
                  "operation" "mysql_query"
                  "args" (sorted-map "sql" sql)))])
    (build-event entity req "check policy" "MySQL")))

(defun parse-mysql-policy (resp)
  "Parse MySQL MCP response for policy status and coverage."
  (let* ([rows (get resp "rows")]
         [row  (if (and (vector? rows) (> (length rows) 0))
                   (first rows)
                   (set-exception-business "MySQL returned no rows"))])
    (sorted-map
      "status"         (get row "STATUS")
      "coverage_limit" (get row "COVERAGE_LIMIT"))))

;; sharepoint
(defun mk-sharepoint-list-docs-event (entity args)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind" "KIND_SHAREPOINT"
                  "operation" "search_sharepoint"
                  "args" (sorted-map
                            "query" (format-string "path:{}"
                                      (get args "folder")))))])
    (build-event entity req "list documents" "SharePoint")))

(defun parse-sharepoint-docs (resp)
  (let* ([docs (get resp "documents")])
    (sorted-map
      "documents"
        (map (lambda (d)
               (sorted-map
                 "type" (get d "type")
                 "file" (get d "file")))
             docs))))


; guidewire 2

(defun mk-guidewire-approval-update-event (entity args)
  (let* ([req (mk-connector-req
                (sorted-map
                  "kind" "KIND_OUTBOUND_REST"
                  "operation" "updateClaimApproval"
                  "args" (sorted-map
                            "claimId"    (get args "claim_id")
                            "approval"   (get args "approval")
                            "approvedBy" (get args "approved_by"))))])
    (build-event entity req "update approval" "Guidewire")))

(defun parse-guidewire-approval-update (resp)
  (sorted-map
    "approval_status" (get resp "status")
    "confirmation"    (get resp "message")))

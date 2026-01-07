;; Copyright © 2025 Luther Systems, Ltd. All right reserved.
;; Unit tests for Workflow 2: Guidewire Processing

(in-package 'cdcs)
(use-package 'testing)

;; Test helper: Create a test entity
(defun mk-test-entity-wf2 ()
  (sorted-map
   "claim_id" "CLM-4567"
   "policy_id" "POL-8872"
   "guidewire_claim_id" "GW-CLM-12345"))

;; Test helper: Create mock Guidewire response
(defun mk-test-guidewire-response ()
  (sorted-map
   "claim_id" "GW-CLM-12345"
   "policy_id" "POL-8872"
   "status" "Approved"
   "handler" "John Handler"))

;; Test helper: Create mock MySQL response
(defun mk-test-mysql-response ()
  (vector
   (sorted-map
    "POLICY_ID" "POL-8872"
    "STATUS" "Active"
    "COVERAGE_LIMIT" 50000.00)))

;; =============================
;; Test: Parse Guidewire Response
;; =============================
(test "parse-guidewire-claim"
      (let* ([resp (mk-test-guidewire-response)]
             [parsed (parse-guidewire-claim resp)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "claim_id") "GW-CLM-12345"))
        (assert (equal? (get parsed "policy_id") "POL-8872"))
        (assert (equal? (get parsed "status") "Approved"))))

;; =============================
;; Test: Parse MySQL Policy Response
;; =============================
(test "parse-mysql-policy"
      (let* ([resp (mk-test-mysql-response)]
             [parsed (parse-mysql-policy resp)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "policy_id") "POL-8872"))
        (assert (equal? (get parsed "status") "Active"))
        (assert (= (get parsed "coverage_limit") 50000.00))))

;; =============================
;; Test: Create Guidewire Event
;; =============================
(test "mk-guidewire-get-claim-event"
      (let* ([entity (mk-test-entity-wf2)]
             [event (mk-guidewire-get-claim-event entity "GW-CLM-12345" (sorted-map :entity-id (get entity "claim_id")))])
        (assert (not (nil? event)))
        (assert (equal? (get event "oid") "CLM-4567"))
        (assert (equal? (get event "sys") "outboundgw"))
        (assert (equal? (get event "eng") "get claim"))))

;; =============================
;; Test: Create MySQL Event
;; =============================
(test "mk-mysql-check-policy-event"
      (let* ([entity (mk-test-entity-wf2)]
             [args (sorted-map "policy_id" "POL-8872")]
             [event (mk-mysql-check-policy-event entity args (sorted-map :entity-id (get entity "claim_id")))])
        (assert (not (nil? event)))
        (assert (equal? (get event "oid") "CLM-4567"))
        (assert (equal? (get event "sys") "mysql"))
        (assert (equal? (get event "eng") "check policy"))))

;; =============================
;; Test: Init State Handler Parse
;; =============================
(test "wf2-claim-init-state-handler-parse"
      (let* ([handler (wf2-claim-init-state-handler)]
             [parse-fn (get handler :parse)]
             [resp (sorted-map
                    "policy_id" "POL-8872"
                    "guidewire_claim_id" "GW-CLM-12345")]
             [entity (sorted-map)]
             [parsed (funcall parse-fn resp entity)])
        (assert (not (nil? parsed)))
        (assert (equal? (get parsed "policy_id") "POL-8872"))
        (assert (equal? (get parsed "guidewire_claim_id") "GW-CLM-12345"))))


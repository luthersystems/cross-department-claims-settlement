(in-package 'cdcs)
(use-package 'testing)

;; --- Helpers to build mock eSignature responses ---

(defun mk-contract (id status sign-page-url)
  (sorted-map
    "id"     id
    "status" status
    "signers"
      (if sign-page-url
        (vector (sorted-map
                  "id" "signer-1"
                  "name" "Jack Clarke"
                  "email" "jack.clarke@luthersystems.com"
                  "sign_page_url" sign-page-url))
        (vector))))  ;; empty vector when no signers

;; Case A: The decoded payload has {"data":{"contract":{...}}}
(defun mk-resp-with-data-contract ()
  (sorted-map
    "data" (sorted-map
             "contract" (mk-contract
                           "f3a1ba6a-6a02-438e-becd-c445369f1a99"
                           "sent"
                           "https://esignatures.com/sign/abc"))))

;; Case B: The decoded payload has {"contract":{...}} (no "data")
(defun mk-resp-with-top-level-contract ()
  (sorted-map
    "contract" (mk-contract
                 "0abb6d04-3190-4633-84d1-27d89346eb8f"
                 "queued"
                 "https://esignatures.com/sign/def")))

;; Case C: No signers in the contract
(defun mk-resp-without-signers ()
  (sorted-map
    "data" (sorted-map
             "contract" (mk-contract
                           "11111111-2222-3333-4444-555555555555"
                           "sent"
                           nil))))

;; --- Unit tests for parse-esignature-create-contract ---

(test "parse-esignature-create-contract: data.contract + signer"
  (let* ([resp (mk-resp-with-data-contract)]
         [out  (parse-esignature-create-contract resp)])
    (assert-equal (get out "contract_id")     "f3a1ba6a-6a02-438e-becd-c445369f1a99")
    (assert-equal (get out "contract_status") "sent")
    (assert-equal (get out "sign_page_url")   "https://esignatures.com/sign/abc")))

; (test "parse-esignature-create-contract: top-level contract + signer"
;   (let* ([resp (mk-resp-with-top-level-contract)]
;          [out  (parse-esignature-create-contract resp)])
;     (assert-equal (get out "contract_id")     "0abb6d04-3190-4633-84d1-27d89346eb8f")
;     (assert-equal (get out "contract_status") "queued")
;     (assert-equal (get out "sign_page_url")   "https://esignatures.com/sign/def")))

; (test "parse-esignature-create-contract: no signers -> no sign_page_url"
;   (let* ([resp (mk-resp-without-signers)]
;          [out  (parse-esignature-create-contract resp)])
;     (assert-equal (get out "contract_id")     "11111111-2222-3333-4444-555555555555")
;     (assert-equal (get out "contract_status") "sent")
;     (assert (nil? (get out "sign_page_url")))))

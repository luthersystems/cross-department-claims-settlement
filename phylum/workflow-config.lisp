(in-package 'sandbox)

;; -----------------------------------------------------------------------------
;; Workflow Chaining Configuration & Helpers
;; -----------------------------------------------------------------------------
;; Central place to toggle workflow chaining behaviour and provide helper
;; utilities that can be shared across routes, workflows, and registrations.

;; Global toggle: set to false to disable WF2 -> WF3 chaining by default.
(set '*wf2-chain-enabled* true)

;; Optional default payload for invoking WF3 when chaining is enabled.
;; Set to () if you prefer to derive values dynamically from the WF2 entity.
(set '*wf2-wf3-default-inputs*
     (sorted-map
       "claim_id"        "CLM-4567"
       "invoice_amount"  "20000.00"
       "signer_name"     "Jack Clarke"
       "signer_email"    "jack.clarke@luthersystems.com"
       "originator_name" "Acme Insurance Ltd."
       "recipient_name"  "BlueRiver Underwriting Partners"
       "issue_date"      "2025-11-05"))

(defun normalize-bool (value &optional default-value)
  "Best-effort boolean coercion with sensible defaults."
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

(defun wf2-should-chain? (entity)
  "Determine whether WF2 should hand off to WF3 for the given entity."
  (normalize-bool (get entity "chain_to_wf3") *wf2-chain-enabled*))

(defun wf2-derive-wf3-inputs (entity parsed)
  "Build a payload for WF3 using WF2 entity data as a fallback."
  (let* ([claim-id (or (get entity "claim_id")
                       (set-exception-business "missing claim_id for WF3 handoff"))]
         [invoice-amount (or (get entity "invoice_amount")
                              (get entity "coverage_limit")
                              (set-exception-business "missing invoice_amount or coverage_limit for WF3 handoff"))]
         [signer-name (or (get entity "signer_name")
                          (get entity "handler")
                          (set-exception-business "missing signer_name or handler for WF3 handoff"))]
         [signer-email (or (get entity "signer_email")
                           (set-exception-business "missing signer_email for WF3 handoff"))]
         [originator-name (or (get entity "originator_name") "Acme Insurance Ltd.")]
         [recipient-name (or (get entity "recipient_name") "BlueRiver Underwriting Partners")]
         [issue-date (or (get entity "issue_date") (format-date (now) "%Y-%m-%d"))])
    (sorted-map
      "claim_id"        claim-id
      "invoice_amount"  invoice-amount
      "signer_name"     signer-name
      "signer_email"    signer-email
      "originator_name" originator-name
      "recipient_name"  recipient-name
      "issue_date"      issue-date)))

(defun wf2-build-wf3-inputs (entity parsed)
  "Construct WF3 inputs, preferring the configured defaults when provided."
  (if (nil? *wf2-wf3-default-inputs*)
      (wf2-derive-wf3-inputs entity parsed)
      *wf2-wf3-default-inputs*))

(defun set-wf2-chain-enabled! (flag)
  "Update the global WF2 chaining toggle at runtime."
  (set '*wf2-chain-enabled* (normalize-bool flag *wf2-chain-enabled*)))

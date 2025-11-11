; (in-package 'sandbox)

; ;; ============================================================================
; ;; Workflow 2 -> Workflow 3 Chain Registration
; ;; ============================================================================
; ;; This file registers the handoff from workflow 2 (Guidewire/MySQL/SP validation)
; ;; to workflow 3 (invoice generation and eSignature).

; ;; Projector function: maps WF2 entity + parsed data -> WF3 chresp
; ;; WF3 init expects:
; ;;   - claim_id
; ;;   - invoice_amount
; ;;   - signer_name
; ;;   - signer_email
; ;;   - originator_name (optional)
; ;;   - recipient_name (optional)
; ;;   - issue_date (optional)
; (defun wf2-to-wf3-projector (entity parsed)
;   (let* ([claim-id (get entity "claim_id")]
;          ;; Try invoice_amount from entity first, then coverage_limit as fallback
;          [invoice-amount (or (get entity "invoice_amount")
;                             (get entity "coverage_limit")
;                             (set-exception-business "missing invoice_amount or coverage_limit"))]
;          ;; Try signer_name from entity first, then handler from Guidewire as fallback
;          [signer-name (or (get entity "signer_name")
;                          (get entity "handler")
;                          (set-exception-business "missing signer_name or handler"))]
;          ;; signer_email should be in entity if passed through WF2 init
;          [signer-email (or (get entity "signer_email")
;                           (set-exception-business "missing signer_email - provide in WF2 init"))]
;          ;; Optional fields with defaults
;          [originator-name (or (get entity "originator_name") "Acme Insurance Ltd.")]
;          [recipient-name (or (get entity "recipient_name") "BlueRiver Underwriting Partners")]
;          [issue-date (or (get entity "issue_date") (format-date (now) "%Y-%m-%d"))])
;     (sorted-map
;       "claim_id"        claim-id
;       "invoice_amount"  invoice-amount
;       "signer_name"     signer-name
;       "signer_email"    signer-email
;       "originator_name" originator-name
;       "recipient_name"  recipient-name
;       "issue_date"      issue-date)))

; ;; Register the chain: when workflow 2 completes (reaches GUIDEWIRE_APPROVED),
; ;; automatically trigger workflow 3.
; ;; Note: This assumes workflow 3's manager (claim-manager from 03-state-reg.lisp)
; ;; is loaded and available. The manager variable name is the same, so the last
; ;; one loaded will be used. For production, consider using distinct manager names.
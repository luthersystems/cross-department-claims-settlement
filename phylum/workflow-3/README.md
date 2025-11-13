# Workflow 3: Invoice Generation & Signature Workflow

## Purpose

Workflow 3 handles the creation of inter-entity settlement invoices. It generates an eSignature contract, syncs the invoice to Salesforce, and dispatches notification emails to signers. This workflow manages the invoice lifecycle from creation through signature request.

## Flow Overview

```
WF3_CLAIM_STATE_INVOICE_INIT
  ↓
WF3_CLAIM_STATE_INVOICE_ESIG_CREATED
  ↓
WF3_CLAIM_STATE_INVOICE_SF_SYNCED
  ↓
WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED
  ↓
WF3_CLAIM_STATE_DONE
```

## States

### 1. `WF3_CLAIM_STATE_INVOICE_INIT`
- **Purpose**: Initialize invoice generation and create eSignature contract
- **Input**: 
  - Required: `claim_id`, `invoice_amount`, `signer_name`, `signer_email`
  - Optional: `originator_name`, `recipient_name`, `issue_date`, `policy_id`
- **Actions**:
  - Validates required fields
  - Uses defaults for optional fields if not provided
  - Emits eSignature event to create contract from template
- **Output**: Transitions to `WF3_CLAIM_STATE_INVOICE_ESIG_CREATED`

### 2. `WF3_CLAIM_STATE_INVOICE_ESIG_CREATED`
- **Purpose**: Process eSignature contract creation and sync to Salesforce
- **Input**: eSignature contract creation response
- **Actions**:
  - Parses contract response (contract_id, sign_page_url, contract_status)
  - Stores eSignature metadata
  - Emits Salesforce event to create invoice record
- **Output**: Transitions to `WF3_CLAIM_STATE_INVOICE_SF_SYNCED`

### 3. `WF3_CLAIM_STATE_INVOICE_SF_SYNCED`
- **Purpose**: Process Salesforce record creation and dispatch email
- **Input**: Salesforce create record response
- **Actions**:
  - Parses Salesforce response (sf_record_id)
  - Stores Salesforce record ID
  - Emits SMTP event to send notification email to signer
- **Output**: Transitions to `WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED`

### 4. `WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED`
- **Purpose**: Finalize invoice workflow after email dispatch
- **Input**: SMTP send response
- **Actions**:
  - Parses SMTP response
  - Stores email dispatch confirmation
  - No additional events
- **Output**: 
  - In unified process: Transitions to `WF4_CLAIM_STATE_INIT`
  - Standalone: Transitions to `WF3_CLAIM_STATE_DONE`

### 5. `WF3_CLAIM_STATE_DONE` (Terminal)
- **Purpose**: Terminal state for standalone workflow execution
- **Actions**: No-op handler for completion
- **Output**: Terminal state (no further transitions)

## External Systems

- **eSignature**: Contract creation and signature management platform
- **Salesforce**: CRM system for invoice record tracking
- **SMTP/Email**: Email service for sending signature request notifications

## Data Flow

### Input Fields
- `claim_id` (required)
- `invoice_amount` / `amount` (required)
- `signer_name` (required)
- `signer_email` (required)
- `originator_name` (optional, defaults to constant)
- `recipient_name` (optional, defaults to constant)
- `issue_date` (optional, defaults to constant)
- `policy_id` (optional)

### Persisted Fields
- All input fields
- `esign_contract_id`
- `esign_sign_page_url`
- `esign_status`
- `sf_record_id`
- `email_dispatched`

## eSignature Contract Details

The contract includes:
- Template-based generation
- Placeholder fields: claim_id, originator_name, recipient_name, issue_date, amount
- Signer configuration with email delivery
- Expiration settings
- Custom email templates for signature request and final contract

## Salesforce Integration

Creates a custom object record (`Inter_Entity_Invoice__c`) with:
- Invoice name (claim-based)
- Claim ID reference
- Contract ID from eSignature
- Amount and status
- Sign page URL
- Signer name

## Email Notification

Sends email to signer with:
- Subject: "Settlement Invoice {claim_id} Sent for Signature"
- Body: Includes claim reference and Salesforce record link
- Recipient: Signer email from entity

## Integration Points

- **From Workflow 2**: Receives claim and signer data when chained
- **To Workflow 4**: When chained, transitions from `WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED` to `WF4_CLAIM_STATE_INIT`
- **Standalone**: Can be invoked independently via `invoke_wf3` endpoint


# Workflow 5: Payment Processing & SAP Integration

## Purpose

Workflow 5 handles the final payment processing stage. It stores payment information in SAP HANA and tracks payment acknowledgements. This workflow completes the claims settlement process by recording payment transactions.

## Flow Overview

```
WF5_CLAIM_STATE_INIT
  ↓
WF5_CLAIM_STATE_AWAITING_APPROVAL
  ↓
WF5_CLAIM_STATE_SAP_PAID
  ↓
WF5_CLAIM_STATE_DONE
```

## States

### 1. `WF5_CLAIM_STATE_INIT`
- **Purpose**: Initialize payment workflow
- **Input**: 
  - Required: `claim_id`, `policy_id`
  - Optional: SAP payload
- **Actions**:
  - Validates required fields
  - Stores claim and policy information
  - No events emitted (waits for approval)
- **Output**: Transitions to `WF5_CLAIM_STATE_AWAITING_APPROVAL`

### 2. `WF5_CLAIM_STATE_AWAITING_APPROVAL`
- **Purpose**: Store payment information in SAP HANA
- **Input**: Approval response or entity data
- **Actions**:
  - Parses incoming data or uses entity SAP payload
  - Emits SAP HANA event to insert payment record into staging table
- **Output**: Transitions to `WF5_CLAIM_STATE_SAP_PAID`

### 3. `WF5_CLAIM_STATE_SAP_PAID`
- **Purpose**: Process SAP payment acknowledgement
- **Input**: SAP payment response
- **Actions**:
  - Parses SAP response (transaction_id, amount, posting_ref, status)
  - Stores payment transaction details
  - No additional events
- **Output**: Transitions to `WF5_CLAIM_STATE_DONE`

### 4. `WF5_CLAIM_STATE_DONE` (Terminal)
- **Purpose**: Terminal state for the entire process
- **Actions**: No-op handler for completion
- **Output**: Terminal state (no further transitions)

## External Systems

- **SAP HANA**: Enterprise resource planning system for payment processing and financial records

## Data Flow

### Input Fields
- `claim_id` (required)
- `policy_id` (required)
- SAP payload (optional, defaults include):
  - `payment_id`
  - `invoice_id`
  - `reference`
  - `vendor_id`
  - `amount`
  - `currency`
  - `payment_method`
  - `payment_date`
  - `status`

### Persisted Fields
- `claim_id`
- `policy_id`
- `sap` (full payload)
- `sap_payment_txn_id`
- `sap_paid_amount`
- `sap_posting_ref`
- `sap_status`

## SAP Payment Staging

Inserts payment record into `PAYMENTS_STAGING` table with:
- Payment ID
- Invoice ID
- Reference number
- Vendor ID
- Amount and currency
- Payment method
- Payment date
- Status

## Payment Transaction Details

After SAP processing, stores:
- Transaction ID (from SAP response or default)
- Paid amount
- Posting reference
- Payment status (from SAP response or default "posted")

## Integration Points

- **From Workflow 4**: Receives claim data when chained
- **Terminal**: This is the final workflow in the unified process
- **Standalone**: Can be invoked independently via `invoke_wf5` endpoint

## Process Completion

When `WF5_CLAIM_STATE_DONE` is reached:
- The entire claims settlement process is complete
- Payment has been recorded in SAP
- All workflows have been executed successfully
- Entity state is persisted as terminal


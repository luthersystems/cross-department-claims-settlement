# Workflow 2: Policy Validation & Document Collection

## Purpose

Workflow 2 validates the policy coverage through Guidewire and MySQL, collects supporting documents from SharePoint, and updates the approval status in Guidewire. This workflow ensures the claim is properly validated and all required documentation is collected before proceeding to invoice generation.

## Flow Overview

```
WF2_CLAIM_STATE_INIT
  ↓
WF2_CLAIM_STATE_GUIDEWIRE_SNAPSHOTTED
  ↓
WF2_CLAIM_STATE_MYSQL_VALIDATED
  ↓
WF2_CLAIM_STATE_SP_DOCS_COLLECTED
  ↓
WF2_CLAIM_STATE_GUIDEWIRE_APPROVED
  ↓
WF2_CLAIM_STATE_DONE
```

## States

### 1. `WF2_CLAIM_STATE_INIT`
- **Purpose**: Initialize workflow and retrieve claim snapshot from Guidewire
- **Input**: `guidewire_claim_id` / `gw_claim_id` (required), optional fields from WF1
- **Actions**:
  - Parses incoming request or entity data
  - Stores claim and policy information
  - Emits Guidewire event to get claim details
- **Output**: Transitions to `WF2_CLAIM_STATE_GUIDEWIRE_SNAPSHOTTED`

### 2. `WF2_CLAIM_STATE_GUIDEWIRE_SNAPSHOTTED`
- **Purpose**: Process Guidewire claim snapshot and validate policy in MySQL
- **Input**: Guidewire claim response
- **Actions**:
  - Parses Guidewire response (claim_id, policy_id, status, handler)
  - Stores Guidewire status
  - Emits MySQL query event to check policy status and coverage
- **Output**: Transitions to `WF2_CLAIM_STATE_MYSQL_VALIDATED`

### 3. `WF2_CLAIM_STATE_MYSQL_VALIDATED`
- **Purpose**: Process MySQL policy validation and collect SharePoint documents
- **Input**: MySQL policy query response
- **Actions**:
  - Parses MySQL response (policy_id, status, coverage_limit)
  - Stores policy validation results
  - Emits SharePoint event to retrieve ID verification documents
- **Output**: Transitions to `WF2_CLAIM_STATE_SP_DOCS_COLLECTED`

### 4. `WF2_CLAIM_STATE_SP_DOCS_COLLECTED`
- **Purpose**: Process SharePoint documents and update Guidewire approval
- **Input**: SharePoint document response
- **Actions**:
  - Parses SharePoint documents (type, file references)
  - Stores document metadata
  - Emits Guidewire event to update claim approval status
- **Output**: Transitions to `WF2_CLAIM_STATE_GUIDEWIRE_APPROVED`

### 5. `WF2_CLAIM_STATE_GUIDEWIRE_APPROVED`
- **Purpose**: Process Guidewire approval confirmation
- **Input**: Guidewire approval update response
- **Actions**:
  - Parses approval response (status, confirmation)
  - Stores approval status and confirmation
  - No events emitted (ready for handoff)
- **Output**: 
  - In unified process: Transitions to `CUSTOM_VALIDATION_STATE` (or `WF3_CLAIM_STATE_INVOICE_INIT` if no custom state)
  - Standalone: Transitions to `WF2_CLAIM_STATE_DONE`

### 6. `WF2_CLAIM_STATE_DONE` (Terminal)
- **Purpose**: Terminal state for standalone workflow execution
- **Actions**: No-op handler for completion
- **Output**: Terminal state (no further transitions)

## External Systems

- **Guidewire**: Claim management system for retrieving claim details and updating approval status
- **MySQL**: Policy database for validating coverage and limits
- **SharePoint**: Document repository for ID verification documents

## Data Flow

### Input Fields
- `guidewire_claim_id` / `gw_claim_id` (required)
- `policy_id` (optional, from WF1)
- `signer_email`, `signer_name` (optional, passed through from WF1)
- `invoice_amount`, `originator_name`, `recipient_name`, `issue_date` (optional, passed through from WF1)

### Persisted Fields
- `guidewire_claim_id` / `gw_claim_id`
- `policy_id`
- `guidewire_status`
- `policy_status`
- `coverage_limit`
- `sp_docs` (SharePoint document metadata)
- `approval_status`
- `approval_confirmation`
- All optional fields passed through from WF1

## Integration Points

- **From Workflow 1**: Receives claim and policy data when chained
- **To Workflow 3**: When chained, transitions from `WF2_CLAIM_STATE_GUIDEWIRE_APPROVED` to `WF3_CLAIM_STATE_INVOICE_INIT` (or through custom validation state)
- **Standalone**: Can be invoked independently via `invoke_wf2` endpoint

## Validation Logic

- Policy must be "Active" status in MySQL
- Coverage limit is validated and stored
- SharePoint documents are collected and validated
- Guidewire approval is updated with handler information


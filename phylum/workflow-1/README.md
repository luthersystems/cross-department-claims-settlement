# Workflow 1: Claim Verification & Identity Screening

## Purpose

Workflow 1 handles the initial claim verification and identity screening process. It retrieves claim details from Oracle, validates the claimant's identity through Equifax screening, and notifies the compliance team via Microsoft Teams.

## Flow Overview

```
WF1_CLAIM_STATE_NEW
  ↓
WF1_CLAIM_STATE_ORACLE_DETAILS_RETRIEVED
  ↓
WF1_CLAIM_STATE_EQUIFAX_VERIFIED
  ↓
WF1_CLAIM_TEAMS_THREAD_CREATED
  ↓
WF1_CLAIM_STATE_DONE
```

## States

### 1. `WF1_CLAIM_STATE_NEW` (Init)
- **Purpose**: Initialize the workflow and retrieve claim data from Oracle
- **Input**: `policy_id` (required), optional fields for downstream workflows
- **Actions**:
  - Parses incoming request data
  - Emits Oracle query event to retrieve claim details
- **Output**: Transitions to `WF1_CLAIM_STATE_ORACLE_DETAILS_RETRIEVED`

### 2. `WF1_CLAIM_STATE_ORACLE_DETAILS_RETRIEVED`
- **Purpose**: Process Oracle claim data and initiate Equifax screening
- **Input**: Oracle query response with claim details
- **Actions**:
  - Parses Oracle response (claim ID, amount, status, claimant details)
  - Stores claim metadata (oracle_claim_id, amount, status)
  - Emits Equifax verification event with claimant information
- **Output**: Transitions to `WF1_CLAIM_STATE_EQUIFAX_VERIFIED`

### 3. `WF1_CLAIM_STATE_EQUIFAX_VERIFIED`
- **Purpose**: Process Equifax screening results and notify Teams
- **Input**: Equifax screening response
- **Actions**:
  - Parses Equifax response (status, PEP/EMB hits, matches)
  - Validates screening results
  - Stores Equifax metadata (status, comments, hit values)
  - Emits Teams notification event (success or alert based on validation)
- **Output**: Transitions to `WF1_CLAIM_TEAMS_THREAD_CREATED`

### 4. `WF1_CLAIM_TEAMS_THREAD_CREATED`
- **Purpose**: Finalize workflow after Teams notification
- **Input**: Teams response
- **Actions**:
  - Parses generic response
  - No additional data staging
- **Output**: 
  - In unified process: Transitions to `WF2_CLAIM_STATE_INIT`
  - Standalone: Transitions to `WF1_CLAIM_STATE_DONE`

### 5. `WF1_CLAIM_STATE_DONE` (Terminal)
- **Purpose**: Terminal state for standalone workflow execution
- **Actions**: No-op handler for completion
- **Output**: Terminal state (no further transitions)

## External Systems

- **Oracle**: Database query to retrieve claim details
- **Equifax**: Identity screening and PEP/EMB checks
- **Microsoft Teams**: Notification system for compliance alerts

## Data Flow

### Input Fields
- `policy_id` (required)
- `gw_claim_id` / `guidewire_claim_id` (optional)
- `signer_email`, `signer_name` (optional, for downstream workflows)
- `invoice_amount`, `originator_name`, `recipient_name`, `issue_date` (optional, for downstream workflows)

### Persisted Fields
- `policy_id`
- `gw_claim_id`
- `oracle_claim_id`
- `amount`
- `status`
- `equifax_status`
- `equifax_comment`
- `equifax_hit_value_pep`
- `equifax_hit_value_emb`
- `equifax_pstatus_det`
- `signer_email`, `signer_name` (passed through for downstream workflows)
- `invoice_amount`, `originator_name`, `recipient_name`, `issue_date` (passed through for downstream workflows)

## Integration Points

- **To Workflow 2**: When chained, transitions from `WF1_CLAIM_TEAMS_THREAD_CREATED` to `WF2_CLAIM_STATE_INIT`
- **Standalone**: Can be invoked independently via `invoke_wf1` endpoint


# Workflow 4: Invoice Processing & Incident Management

## Purpose

Workflow 4 handles the creation of invoices in Zoho Books, retrieves supporting documents from SharePoint, and creates ServiceNow incidents for tracking. This workflow manages the operational aspects of invoice processing and incident tracking.

## Flow Overview

```
WF4_CLAIM_STATE_INIT
  ↓
WF4_CLAIM_STATE_ZOHO_INVOICE_CREATED
  ↓
WF4_CLAIM_STATE_SHAREPOINT_DOC_RETRIEVED
  ↓
WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED
  ↓
WF4_CLAIM_STATE_DONE
```

## States

### 1. `WF4_CLAIM_STATE_INIT`
- **Purpose**: Initialize workflow and create invoice in Zoho Books
- **Input**: 
  - Required: `claim_id`
  - Optional: `policy_id`, Zoho payload, SharePoint config, ServiceNow payload
- **Actions**:
  - Parses incoming request or entity data
  - Uses defaults for Zoho, SharePoint, and ServiceNow if not provided
  - Emits Zoho event to create invoice
- **Output**: Transitions to `WF4_CLAIM_STATE_ZOHO_INVOICE_CREATED`

### 2. `WF4_CLAIM_STATE_ZOHO_INVOICE_CREATED`
- **Purpose**: Process Zoho invoice creation and retrieve SharePoint documents
- **Input**: Zoho invoice creation response
- **Actions**:
  - Parses Zoho response (invoice_id, invoice_number, status, totals, etc.)
  - Stores Zoho invoice metadata
  - Emits SharePoint event to retrieve drive item
- **Output**: Transitions to `WF4_CLAIM_STATE_SHAREPOINT_DOC_RETRIEVED`

### 3. `WF4_CLAIM_STATE_SHAREPOINT_DOC_RETRIEVED`
- **Purpose**: Process SharePoint document retrieval and create ServiceNow incident
- **Input**: SharePoint drive item response
- **Actions**:
  - Parses SharePoint response (item_id, name, web_url, download_url)
  - Stores SharePoint document metadata
  - Emits ServiceNow event to create incident
- **Output**: Transitions to `WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED`

### 4. `WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED`
- **Purpose**: Process ServiceNow incident creation
- **Input**: ServiceNow incident creation response
- **Actions**:
  - Parses ServiceNow response (incident_id, incident_number, state, URL)
  - Stores ServiceNow incident metadata
  - No additional events
- **Output**: 
  - In unified process: Transitions to `WF5_CLAIM_STATE_INIT`
  - Standalone: Transitions to `WF4_CLAIM_STATE_DONE`

### 5. `WF4_CLAIM_STATE_DONE` (Terminal)
- **Purpose**: Terminal state for standalone workflow execution
- **Actions**: No-op handler for completion
- **Output**: Terminal state (no further transitions)

## External Systems

- **Zoho Books**: Accounting system for invoice creation and management
- **SharePoint**: Document repository for retrieving supporting documents
- **ServiceNow**: IT service management for incident tracking

## Data Flow

### Input Fields
- `claim_id` (required)
- `policy_id` (optional, defaults to constant)
- Zoho payload (optional, defaults include):
  - `customer_id`
  - `reference_number` (derived from claim_id)
  - `due_date`
  - `is_inclusive_tax`
  - `currency_code`
  - `line_items`
- SharePoint config (optional, defaults include):
  - `site_id`
  - `drive_id`
  - `item_id`
  - `filename`
- ServiceNow payload (optional, defaults include):
  - `short_description`
  - `description`
  - `priority`
  - `category`
  - `impact`
  - `urgency`
  - `assignment_group`

### Persisted Fields
- `claim_id`
- `policy_id`
- `zoho` (full payload)
- `sharepoint` (full config)
- `servicenow` (full payload)
- `zoho_invoice_id`
- `zoho_invoice_number`
- `zoho_invoice_status`
- `zoho_invoice_url`
- `zoho_invoice_total`
- `zoho_invoice_balance`
- `zoho_customer_id`
- `zoho_customer_name`
- `sharepoint_documents` (with retrieved_at timestamp)
- `servicenow_incident_id`
- `servicenow_incident_number`
- `servicenow_state`
- `servicenow_url`
- `servicenow_short_description`

## Zoho Invoice Details

Creates invoice with:
- Customer ID from defaults
- Reference number based on claim ID
- Due date, tax settings, currency
- Line items from defaults
- Automatic invoice numbering

## SharePoint Integration

Retrieves drive item using:
- Site ID, Drive ID, Item ID from configuration
- Returns document metadata including download URLs

## ServiceNow Incident Details

Creates incident with:
- Short description: "Create incident for claim {claim_id}"
- Category: Finance
- Priority, impact, urgency from defaults
- Assignment group: Finance Ops
- Auto-generated incident number

## Integration Points

- **From Workflow 3**: Receives claim data when chained
- **To Workflow 5**: When chained, transitions from `WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED` to `WF5_CLAIM_STATE_INIT`
- **Standalone**: Can be invoked independently via `invoke_wf4` endpoint


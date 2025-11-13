# Cross-Department Claims Settlement - State Machine Documentation

## Overview

This system implements a unified state machine framework for orchestrating cross-department claims settlement workflows. The system manages the entire lifecycle from initial claim verification through payment processing, integrating with multiple external systems (Oracle, Equifax, Guidewire, MySQL, SharePoint, eSignature, Salesforce, Zoho, ServiceNow, SAP, Teams, SMTP).

## Architecture

### State Machine Framework

The state machine is built on a declarative framework where:

1. **Entity Managers** manage domain entities (e.g., "claim")
2. **State Handlers** define behavior for each state
3. **State Specs** map state names to handlers
4. **Ephemeral Storage** provides temporary data storage between states
5. **Durable Storage** persists entity state permanently

### Core Components

- **`substrate/substr_generic_state_machine.lisp`**: Core state machine runtime
- **`substrate/substr_ephemeral_storage.lisp`**: Ephemeral storage management
- **`substrate/substr_connector.lisp`**: ConnectorHub integration layer
- **`substrate/substr_generic_parser.lisp`**: Generic response parsing utilities
- **`parsers/`**: External system-specific parsers (Oracle, Equifax, Teams, etc.)

## How the State Machine Works

### State Handler Structure

Each state handler is defined using `mk-state-handler` with four hooks:

```lisp
(defun my-state-handler (&optional next-state)
  (labels
    ([parse (resp entity)
       ;; 1. Parse and validate incoming data
       ;; Returns: sorted-map of parsed values
       (sorted-map "field1" (get resp "field1"))]
     
     [stage-ephemeral (entity parsed accessors)
       ;; 2. Stage temporary data (dropped at specified state)
       ;; Returns: vector of ephemeral intents
       (vector)]
     
     [stage-durable (entity parsed accessors)
       ;; 3. Stage persistent data (merged into entity)
       ;; Returns: sorted-map of durable fields
       (sorted-map "field1" (get parsed "field1"))]
     
     [create-events (entity parsed accessors)
       ;; 4. Emit connector events (external system calls)
       ;; Returns: vector of events
       (vector (mk-some-event entity args))])
    
    (mk-state-handler
      :next            (or next-state "NEXT_STATE")
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events
      :immediate-next  (if next-state true false)
      :terminal        (not next-state))))
```

### Execution Flow

For each state transition:

1. **Parse**: Validates and normalizes input data (`resp` and `entity`)
2. **Stage Ephemeral**: Stores temporary data (auto-dropped at specified `drop-state`)
3. **Stage Durable**: Merges persistent data into entity
4. **Create Events**: Emits connector events (external system calls)
5. **Transition**: Moves to `:next` state
6. **Persistence**: If `:terminal`, entity is persisted immediately

### Key Concepts

#### Immediate Transitions (`:immediate-next`)

When `:immediate-next` is `true` and no events are emitted, the state machine synchronously processes the next state without waiting for ConnectorHub callbacks. This enables seamless workflow chaining.

#### Terminal States (`:terminal`)

Terminal states mark the end of a workflow. When reached:
- Entity state is persisted immediately (even without events)
- Completion notifications are logged
- No further transitions occur

#### Data Prioritization

Handlers use a consistent pattern for data extraction:
```lisp
(or (get resp "field")      ; 1. Explicit request data
    (get entity "field")     ; 2. Accumulated entity data
    default-value)           ; 3. Default constant
```

This allows workflows to work both:
- **Standalone**: When invoked directly via routes (resp has data)
- **Chained**: When part of unified process (resp empty, uses entity)

## Workflow Chaining

### Individual Workflows

Each workflow (WF1-WF5) can be invoked independently:

- **WF1**: `invoke_wf1` - Claim verification & identity screening
- **WF2**: `invoke_wf2` - Policy validation & document collection
- **WF3**: `invoke_wf3` - Invoice generation & signature workflow
- **WF4**: `invoke_wf4` - Invoice processing & incident management
- **WF5**: `invoke_wf5` - Payment processing & SAP integration

### Unified Process

The unified process (`invoke_process`) chains all workflows together:

```
WF1_CLAIM_STATE_NEW
  → WF1_CLAIM_TEAMS_THREAD_CREATED
  → WF2_CLAIM_STATE_INIT
  → WF2_CLAIM_STATE_GUIDEWIRE_APPROVED
  → CUSTOM_VALIDATION_STATE (optional)
  → WF3_CLAIM_STATE_INVOICE_INIT
  → WF3_CLAIM_STATE_INVOICE_EMAIL_DISPATCHED
  → WF4_CLAIM_STATE_INIT
  → WF4_CLAIM_STATE_SERVICENOW_INCIDENT_CREATED
  → WF5_CLAIM_STATE_INIT
  → WF5_CLAIM_STATE_DONE (terminal)
```

### How Chaining Works

1. **State Spec Merging**: Individual workflow state specs are merged into `state-spec-claim`
2. **Transition Overrides**: Specific handlers are overridden to route to the next workflow's initial state
3. **Immediate Transitions**: Handlers use `:immediate-next` to synchronously transition when no events are emitted
4. **Data Flow**: Each workflow reads from accumulated entity data, ensuring data flows through the chain

Example override in `process-reg.lisp`:
```lisp
"WF1_CLAIM_TEAMS_THREAD_CREATED" (wf1-teams-thread-created-state-handler "WF2_CLAIM_STATE_INIT")
```

## Custom State Transitions

You can insert custom states anywhere in the process chain:

### 1. Define Custom Handler

```lisp
(defun custom-validation-state-handler (&optional next-state)
  (labels
    ([parse (resp entity)
       ;; Your custom logic
       (sorted-map "validated" true)]
     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable (entity parsed accessors)
       (sorted-map "custom_field" (get parsed "validated"))]
     [create-events (entity parsed accessors) (vector)])
    (mk-state-handler
      :next            (or next-state "CUSTOM_COMPLETE")
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events
      :immediate-next  (if next-state true false))))
```

### 2. Add to State Spec

```lisp
(set 'state-spec-claim
     (merge-state-specs
       state-spec-wf1
       state-spec-wf2
       (sorted-map "CUSTOM_VALIDATION_STATE" (custom-validation-state-handler))
       state-spec-wf3
       ;; ... rest of workflows
       ))
```

### 3. Route Through Custom State

```lisp
;; In overrides section:
"WF2_CLAIM_STATE_GUIDEWIRE_APPROVED" (wf2-claim-guidewire-approved-state-handler "CUSTOM_VALIDATION_STATE")
"CUSTOM_VALIDATION_STATE"            (custom-validation-state-handler "WF3_CLAIM_STATE_INVOICE_INIT")
```

## Entity Management

### Entity Structure

Entities are stored in SideDB with the key pattern:
```
sandbox:<entity-name>:<entity-id>
```

Example: `sandbox:claim:550e8400-e29b-41d4-a716-446655440000`

### Entity Fields

- **Primary Key**: `claim_id` (UUID)
- **State**: Current state name (e.g., `WF1_CLAIM_STATE_NEW`)
- **Durable Fields**: All fields persisted via `stage-durable`
- **Ephemeral Fields**: Stored separately, auto-dropped at specified states

### Ephemeral Storage

Ephemeral data is stored with automatic cleanup:
- **Bucket**: `sandbox:<entity>:ephem:bucket:<entityId>:<dropState>`
- **Router**: `sandbox:<entity>:ephem:router:<entityId>:<key>`
- **Index**: `sandbox:<entity>:ephem:index:<entityId>:<dropState>`

Data is automatically purged when the entity enters the `drop-state`.

## ConnectorHub Integration

### Event Emission

Events are emitted via `build-event`:
```lisp
(build-event entity req "action description" "SYSTEM_NAME")
```

### Event Response Handling

When ConnectorHub responds:
1. Response is passed to the handler's `parse` function
2. Parsed data flows through `stage-ephemeral` and `stage-durable`
3. State transitions to `:next`

### External Systems

The system integrates with:
- **Oracle**: Database queries
- **Equifax**: Identity screening
- **Guidewire**: Claim management
- **MySQL**: Policy validation
- **SharePoint**: Document retrieval
- **eSignature**: Contract creation
- **Salesforce**: CRM records
- **Zoho**: Invoice management
- **ServiceNow**: Incident tracking
- **SAP**: Payment processing
- **Teams**: Notifications
- **SMTP**: Email delivery

## File Organization

```
phylum/
├── substrate/              # Core framework
│   ├── substr_generic_state_machine.lisp
│   ├── substr_ephemeral_storage.lisp
│   ├── substr_connector.lisp
│   └── substr_generic_parser.lisp
├── parsers/                 # External system parsers
│   ├── oracle.lisp
│   ├── equifax.lisp
│   ├── guidewire.lisp
│   └── ...
├── workflow-1/              # Workflow 1: Claim Verification
│   ├── 01-constants.lisp
│   ├── 01-parsers.lisp
│   ├── 01-workflow.lisp
│   ├── 01-routes.lisp
│   ├── 01-reg.lisp
│   └── README.md
├── workflow-2/              # Workflow 2: Policy Validation
│   └── ...
├── workflow-3/              # Workflow 3: Invoice Generation
│   └── ...
├── workflow-4/              # Workflow 4: Invoice Processing
│   └── ...
├── workflow-5/              # Workflow 5: Payment Processing
│   └── ...
├── process-reg.lisp         # Unified process registration
├── workflow-chaining.lisp   # Workflow chaining infrastructure
├── main.lisp                # Entry point
└── README.md                # This file
```

## Usage Examples

### Invoke Unified Process

```bash
curl -X POST http://localhost:8080/v1/invoke_process \
  -H "Content-Type: application/json" \
  -d '{
    "policy_id": "POL-12345",
    "guidewire_claim_id": "CLM-67890"
  }'
```

### Invoke Individual Workflow

```bash
curl -X POST http://localhost:8080/v1/invoke_wf1 \
  -H "Content-Type: application/json" \
  -d '{
    "policy_id": "POL-12345"
  }'
```

## Best Practices

1. **Keep Parse Pure**: Only validate and normalize; never mutate entity
2. **Use Ephemeral for Large Data**: Store bulky/temporary data in ephemeral storage
3. **Use Durable for Identifiers**: Persist IDs, statuses, and references
4. **Idempotent Handlers**: Design handlers to be safe on reruns
5. **Error Handling**: Use `set-exception-business` for user errors, `set-exception-unexpected` for system errors
6. **Data Flow**: Always prioritize `resp` → `entity` → `default` pattern
7. **Terminal States**: Mark terminal states with `:terminal true`
8. **Immediate Transitions**: Use `:immediate-next` for synchronous workflow chaining

## Troubleshooting

### State Not Transitioning

- Check that `:next` is set correctly
- Verify `:immediate-next` is set if no events are emitted
- Ensure handler is registered in state spec

### Data Not Persisting

- Verify `stage-durable` returns the fields you want
- Check that terminal states have `:terminal true`
- Ensure `storage-put` is available in the state machine

### Events Not Emitting

- Verify `create-events` returns a vector (even if empty)
- Check that `build-event` is called correctly
- Ensure ConnectorHub is configured for the system

## See Also

- [Workflow 1 Documentation](workflow-1/README.md)
- [Workflow 2 Documentation](workflow-2/README.md)
- [Workflow 3 Documentation](workflow-3/README.md)
- [Workflow 4 Documentation](workflow-4/README.md)
- [Workflow 5 Documentation](workflow-5/README.md)

## Part 1: 



1. run-state-step called
   ↓
   Parameters:
   - entity-name: "claim_wf4"
   - entity-key: "claim_id"
   - instance: { "state": "STATE_A", "claim_id": "abc-123", ... }
   - resp: { "some_data": "value" }  (or empty map)
   - states: state-spec map
   ↓

2. Read CURRENT state from entity
   ↓
   [state (get instance "state")]  ; state = "STATE_A"
   ↓

3. Lookup handler for STATE_A
   ↓
   [spec (lookup-state-spec "STATE_A" states)]  ; Gets STATE_A handler spec
   ↓

4. Execute STATE_A handler hooks:
   ↓
   a) parse(resp, instance)
      → Returns parsed data
   ↓
   b) stage-ephemeral(instance, parsed, accessors)
      → Returns ephemeral intents (vector)
   ↓
   c) stage-durable(instance, parsed, accessors)
      → Returns durable updates (map)
   ↓
   d) Merge durable updates into entity
      [durable-entity (make-mergemap instance staged-durable)]
   ↓
   e) create-events(durable-entity, parsed, accessors)
      → Returns events vector (EMPTY in this scenario)
   ↓

5. Get next-state from spec
   ↓
   [next-state (spec-next spec)]  ; next-state = "STATE_B"
   ↓

6. Persist ephemerals (if any)
   ↓
   (ephem-persist-staged! ...)  ; Only if staged-ephemeral has items
   ↓

7. Advance state to next-state
   ↓
   (assoc! durable-entity "state" "STATE_B")
   ↓
   durable-entity now = { "state": "STATE_B", "claim_id": "abc-123", ... }
   ↓

8. Check if next-state is terminal
   ↓
   (lookup-state-spec "STATE_B" states) → Check :terminal flag
   ↓

9. Purge ephemerals for STATE_B (if any)
   ↓
   (ephem-purge-for-state! ...)
   ↓

10. Check :immediate-next flag
    ↓
    [immediate-next (spec-immediate-next spec)]  ; = true (for STATE_A)
    [events-vector (if (vector? events) events (vector))]  ; = empty vector
    [no-events (equal? (length events-vector) 0)]  ; = true
    ↓
    Condition: (and true true (not (equal? "STATE_B" "STATE_UNKNOWN")))
    → TRUE, so proceed to recursive call
    ↓

11. Recursive call to run-state-step for STATE_B
    ↓
    (run-state-step entity-name entity-key durable-entity (sorted-map) states)
    ↓
    Note: durable-entity already has state="STATE_B"
    Note: resp is empty map (sorted-map) - no new data

## Part 2: Inbound rest

0. External HTTP Request
   ↓
   POST /contract-signed
   {
     "claimID": "abc-123",
     "signedBy": "john@example.com",
     "verifiedBy": "jack@luthersystems.com"
   }
   ↓

1. ConnectorHub receives HTTP request
   ↓
   - Validates against OpenAPI spec
   - Packages request into transient data: $ch_rep:0
   ↓

2. ConnectorHub calls phylum endpoint
   ↓
   - Calls: contract_signed_handler (target_endpoint from connectorhub.yaml)
   - Request data available via: transient:get "$ch_rep:0"
   ↓

3. contract_signed_handler executes
   ↓
   - Extracts claimID, signedBy, verifiedBy from transient data
   - Loads entity from state DB: (claim-manager 'get claim-id)
   - Validates entity exists and is in WAITING_FOR_SIGNATURE state
   ↓

4. trigger-connector-object called
   ↓
   (trigger-connector-object 
     claim-manager 
     claim-id 
     (sorted-map "signedBy" signed-by "verifiedBy" verified-by))
   ↓

5. Entity loaded (state = WAITING_FOR_SIGNATURE)
   ↓
   (obj-factory 'get obj-id)  ; Loads from SideDB
   ↓

6. obj 'handle invoked
   ↓
   (obj 'handle resp ctx)  ; Calls entity instance's handle method
   ↓

7. run-state-step called with CURRENT state (WAITING_FOR_SIGNATURE)
   ↓
   (run-state-step entity-name entity-key entity resp states)
   ↓

8. Handler for WAITING_FOR_SIGNATURE executes:
   ↓
   - parse() runs (extracts signedBy/verifiedBy from resp)
   - stage-durable() runs (stores signedBy/verifiedBy)
   - create-events() runs (returns empty vector)
   ↓

9. State advanced to next-state (CONTRACT_SIGNED) - Line 178
   ↓
   (assoc! durable-entity "state" "WF4_CLAIM_STATE_CONTRACT_SIGNED")
   ↓

10. Check :immediate-next flag
    ↓
    - :immediate-next = false (for WAITING_FOR_SIGNATURE)
    - So NO recursive call
    ↓

11. Return transition result
    ↓
    (sorted-map "put" durable-entity "events" (vector))
    ↓

12. do-transition executes
    ↓
    - Persists entity to SideDB: (obj-factory 'put put-obj)
    - Emits events (none in this case)
    ↓

13. contract_signed_handler returns success response
    ↓
    (route-success (sorted-map "claim_id" claim-id "state" "CONTRACT_SIGNED"))
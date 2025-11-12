# Adding Stages to the State Machine

This guide explains how to add new **stages** (states and handlers) to the workflow state machine that powers the claims/invoice flows. It uses your current code style (Common Lisp–like DSL), helpers (e.g., `parse-generic-resp`), and conventions (`sorted-map`, `vector`, etc.).

---

## Key Concepts

- **Entity**: A domain object managed by an entity manager (e.g., a `claim` or `invoice`). It has a primary key (e.g., `claim_id`) and a `state` field.
- **State**: A named step in the workflow (e.g., `CLAIM_STATE_NEW`). Each state has a **handler** that defines how to parse input, stage data, and emit events.
- **Handler**: Built via `mk-state-handler`, providing four hooks:
  - `:parse (resp entity)` → returns a parsed map used by later hooks
  - `:stage-ephemeral (entity parsed accessors)` → returns ephemeral key/value pairs (discarded after a downstream state)
  - `:stage-durable (entity parsed accessors)` → returns durable key/value pairs persisted to the entity
  - `:create-events (entity parsed accessors)` → returns a vector of connector events to emit
- **Transition**: The handler includes `:next` to declare the next state upon success.
- **Accessors**: Helpers provided to handlers (e.g., `:get-ephem`) to read previously staged ephemeral data.

---

## Anatomy of a State Handler

```lisp
(defun <state-name>-state-handler ()
  (labels
    ([parse (resp entity)
      ;; Validate + extract everything needed for this step. Should not persist.
      <return-sorted-map-of-parsed-values>]

     [stage-ephemeral (entity parsed accessors)
      ;; Return ephemeral k/v pairs (vector of maps with :key, :value, :drop-state)
      <return-ephemerals-or-empty>]

     [stage-durable (entity parsed accessors)
      ;; Return durable fields to persist to the entity record
      <return-durable-or-empty>]

     [create-events (entity parsed accessors)
      ;; Return events to fire (external connectors, internal actions, etc.)
      <return-vector-of-events>])

    (mk-state-handler
      :next            "<NEXT_STATE>"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))
```

### When to use each hook
- **`parse`**: Validate inputs and normalize data. Do *not* mutate the entity here.
- **`stage-ephemeral`**: Temporarily keep bulky/short‑lived data (e.g., raw file content). Drop it automatically at `:drop-state`.
- **`stage-durable`**: Persist long‑lived fields to the entity (identifiers, statuses, references).
- **`create-events`**: Emit connector events (e.g., S3 upload, MySQL select/update). Use durable + parsed data.

---

## Adding a New Stage: Step‑by‑Step

### 1) Define the handler
Start with the pattern above. Implement `parse`, `stage-ephemeral`, `stage-durable`, and `create-events` for your use case.

**Example: Claim → fetch user details by policy**

```lisp
(defun claim-mysql-retrieved-state-handler ()
  (labels
    ([parse (resp entity)
      ;; Use your generic MySQL parser helper (already defined):
      ;; `parse-generic-resp` parses `response.generic.text` JSON into rows.
      (let* ([parsed (parse-generic-resp resp :skip-inner-error-check t)]
             [rows   (if (vector? parsed) parsed (list parsed))]
             [row    (and (not (empty? rows)) (nth 0 rows))]
             [full   (and row (get row "full_name"))]
             [email  (and row (get row "email"))])
        (when (or (null full) (null email))
          (set-exception-unexpected "mysql parse error: missing full_name/email"))
        (sorted-map "full_name" full "email" email))]

     [stage-ephemeral (entity parsed accessors)
      ;; No ephemerals needed here
      (vector)]

     [stage-durable (entity parsed accessors)
      ;; Persist the user details onto the claim for observability
      (sorted-map
        "user_full_name" (get parsed "full_name")
        "user_email"     (get parsed "email"))]

     [create-events (entity parsed accessors)
      ;; No downstream events in this example
      (vector)])

    (mk-state-handler
      :next            "CLAIM_STATE_DONE"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))
```

> If you need the stage to *trigger* a MySQL read itself, move the MySQL event emission into `create-events` and set `:next` to the next logical state (e.g., `CLAIM_STATE_MYSQL_RETRIEVED`). Then, in that next state’s `parse`, consume the MySQL result.

### 2) Register the state in the machine

Add the new mapping to your `state-spec`:

```lisp
(set 'state-spec
  (sorted-map
    "CLAIM_STATE_NEW"             (claim-init-state-handler)
    "CLAIM_STATE_ORACLE_RETRIEVED" (claim-oracle-retrieved-state-handler) ; if you have one
    "CLAIM_STATE_MYSQL_RETRIEVED" (claim-mysql-retrieved-state-handler)
    "CLAIM_STATE_DONE"            (claim-done-state-handler)))
```

> Order in the `sorted-map` does not impose execution order, but keeping a logical order improves readability.

### 3) Wire the route → initial trigger

Your route already does this correctly:

```lisp
(defendpoint "upload_claim_wf1" (req)
  (let* ([policy-id (or (get req "policy_id")
                        (set-exception-business "missing policy_id"))]
         [claim     (new-connector-object claim-manager)]
         [claim-id  (get claim "claim_id")]
         [chresp    (sorted-map "policy_id" policy-id)])
    (trigger-connector-object claim-manager claim-id chresp)
    (route-success (sorted-map "claim_id" claim-id "state" "CLAIM_STATE_ORACLE_RETRIEVED"))))
```

- The **first** state that runs is the manager’s initial state (e.g., `CLAIM_STATE_NEW`). That handler’s `create-events` should emit whatever is needed (e.g., an Oracle lookup, then MySQL read), and `:next` should point to the subsequent state.

---

## Example: Emitting a MySQL Select by `policy_id`

**Event creation (from an earlier state)**
```lisp
(defun claim-oracle-retrieved-state-handler ()
  (labels
    ([parse (resp entity)
      ;; suppose resp already has policy_id
      (let* ([pid (or (get resp "policy_id") (set-exception-business "missing policy_id"))])
        (sorted-map "policy_id" pid))]

     [stage-ephemeral (entity parsed accessors) (vector)]
     [stage-durable   (entity parsed accessors) (sorted-map "policy_id" (get parsed "policy_id"))]

     [create-events (entity parsed accessors)
      (let* ([pid (get entity "policy_id")])
        (vector (mk-mysql-select-event
                  entity
                  (mk-mysql-req
                    :sql   "SELECT * FROM v_user_details_by_policy WHERE policy_id = ?"
                    :params (list pid)))) )])

    (mk-state-handler
      :next            "CLAIM_STATE_MYSQL_RETRIEVED"
      :parse           parse
      :stage-ephemeral stage-ephemeral
      :stage-durable   stage-durable
      :create-events   create-events)))
```

> Prefer parameterized SQL (`?` + `:params`) to safely handle hyphens and quoting (e.g., `policy-id`).

---

## Conventions & Best Practices

1. **Keep `parse` pure**: Only validate and normalize; never persist.
2. **Ephemeral vs Durable**:
   - Use **ephemeral** for large/temporary payloads (e.g., file bytes), with `:drop-state` to auto-clean.
   - Use **durable** for identifiers and state you want on the entity long‑term.
3. **Idempotency**: Design handlers so reruns don’t corrupt state. Selects should be safe; updates should be conditional or use upserts.
4. **Errors**: Use `set-exception-business` for user/input issues and `set-exception-unexpected` for system/parse failures.
5. **Logging**: Keep `cc:infof` breadcrumbs per sub‑hook (`parse`, `stage-*`, `create-events`) to simplify tracing.
6. **Transitions**: Choose the smallest next state that can make a decision. Avoid handlers that both call out and fully finish; prefer one external call per state for clearer retries.
7. **Testing**:
   - Unit test each hook in isolation.
   - Simulate connector responses using your `generic.text` payloads.
   - Verify ephemerals are dropped at the intended `:drop-state`.

---


## Minimal Checklist for a New Stage

- [ ] Implement `parse`, `stage-ephemeral`, `stage-durable`, `create-events`.
- [ ] Add the state to `state-spec` with the correct `:next`.
- [ ] Ensure previous state emits the right event(s) to reach this state.
- [ ] Prefer parameterized SQL for all DB interactions.
- [ ] Add logs in each hook.
- [ ] Add unit tests for parse/staging/event emission.

---


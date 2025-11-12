(in-package 'sandbox)

;; ============================================================================
;; Workflow Chaining Infrastructure
;; ============================================================================
;; Allows workflows to automatically hand off to the next workflow in a chain
;; by registering workflow transitions and projection functions.

;; Global registry: maps workflow name -> (sorted-map :next-name :projector :next-manager)
(set 'workflow-chain-registry (sorted-map))

;; Global registry: maps workflow name -> manager
;; Allows invoking workflows by name
(set 'workflow-registry (sorted-map))

;; Global registry: maps workflow name -> completion listener function
;; Completion listeners are called when a workflow reaches its done state
(set 'workflow-completion-listeners (sorted-map))

;; Register a workflow manager with a name for easy invocation
(defun register-workflow (name manager)
  "Register a workflow manager with a name (e.g., 'wf2', 'wf3')"
  (set 'workflow-registry
       (assoc workflow-registry name manager)))

;; Lookup a workflow manager by name
(defun lookup-workflow (name)
  "Look up a workflow manager by name"
  (get workflow-registry name))

;; Register a workflow chain: when 'from-name' completes, trigger 'to-name'
;; using 'projector-fn' to map (entity parsed) -> chresp for the next workflow.
;; 'next-manager' is the connector manager for the target workflow.
(defun register-workflow-chain (from-name to-name projector-fn next-manager)
  (set 'workflow-chain-registry
       (assoc workflow-chain-registry from-name
         (sorted-map
           :next-name to-name
           :projector projector-fn
           :next-manager next-manager))))

;; Lookup the next workflow configuration for a given workflow name.
(defun lookup-next-workflow (name)
  (get workflow-chain-registry name))

;; Hand off from the current workflow to the next one.
;; This is called automatically when a workflow reaches a handoff state.
;; Since workflows are async, this immediately triggers the next workflow
;; without waiting for the current one to fully complete.
;;
;; 'from-name' is the name of the current workflow (e.g., "wf2")
;; 'entity' is the current entity state
;; 'parsed' is the parsed response from the current state handler
;; Returns the claim_id of the newly created workflow object, or nil if no chain registered.
(export 'handoff-to-next)
(defun handoff-to-next (from-name entity parsed)
  (let* ([entry (lookup-next-workflow from-name)]
         [projector (and entry (get entry :projector))]
         [next-manager (and entry (get entry :next-manager))])
    (when (nil? entry)
      (cc:infof (sorted-map "from_workflow" from-name) "No chained workflow registered")
      (return))  ; No chain registered, just return (not an error)
    (when (nil? projector)
      (set-exception-business
        (format-string "Chained workflow {} has no projector function" from-name)))
    (when (nil? next-manager)
      (set-exception-business
        (format-string "Chained workflow {} has no next-manager" from-name)))
    
    ;; Build the chresp for the next workflow using the projector
    (let* ([chresp (projector entity parsed)])
      (when (nil? chresp)
        (set-exception-business
          (format-string "Chained projector returned nil for {}" from-name)))
      
      ;; Invoke the next workflow using the projected inputs
      ;; This uses invoke-workflow which handles entity creation and triggering
      ;; Since workflows are async, this returns immediately after triggering
      (let* ([next-workflow-name (get entry :next-name)]
             [result (invoke-workflow next-manager chresp)])
        (cc:infof
          (sorted-map
            "from_workflow" from-name
            "to_workflow" next-workflow-name
            "next_claim_id" (get result "claim_id")
            "next_state" (get result "state"))
          "Handed off to next workflow")
        (get result "claim_id")))))

;; ============================================================================
;; Workflow Completion Listeners
;; ============================================================================

;; Register a completion listener for a workflow.
;; The listener function will be called when the workflow reaches its done state.
;; Listener signature: (listener-fn workflow-name entity)
(export 'register-workflow-completion-listener)
(defun register-workflow-completion-listener (workflow-name listener-fn)
  (set 'workflow-completion-listeners
       (assoc workflow-completion-listeners workflow-name listener-fn)))

;; Helper: determine workflow name from entity-name
;; Maps entity-name patterns to workflow names (e.g., "claim_wf2" -> "wf2")
(defun entity-name-to-workflow-name (entity-name)
  (cond
    ((equal? entity-name "claim_wf2") "wf2")
    ((equal? entity-name "claim_wf3") "wf3")
    ((equal? entity-name "claim_wf1") "wf1")
    ((equal? entity-name "claim_wf4") "wf4")
    ((equal? entity-name "claim_wf5") "wf5")
    (:else nil)))

;; Notify all completion listeners that a workflow has completed.
;; This is called from the done state handler.
;; 'workflow-name' is the name of the workflow (e.g., "wf2", "wf3")
;; 'entity' is the entity that completed
(export 'notify-workflow-completion)
(defun notify-workflow-completion (workflow-name entity)
  (let* ([listener (get workflow-completion-listeners workflow-name)])
    (when listener
      (listener workflow-name entity))
    ;; Also log a simple message
    (cc:infof
      (sorted-map
        "workflow" workflow-name
        "claim_id" (get entity "claim_id")
        "state" (get entity "state"))
      (format-string "{} workflow completed!" workflow-name))))

;; Notify workflow completion by entity-name.
;; This is a convenience function that determines the workflow name from entity-name.
;; 'entity-name' is the entity name (e.g., "claim_wf2", "claim_wf3")
;; 'entity' is the entity that completed
(export 'notify-workflow-completion-by-entity-name)
(defun notify-workflow-completion-by-entity-name (entity-name entity)
  (let* ([workflow-name (entity-name-to-workflow-name entity-name)])
    (when workflow-name
      (notify-workflow-completion workflow-name entity))))

;; ============================================================================
;; Workflow Invocation Wrapper
;; ============================================================================

(export 'invoke-workflow)
;; Invoke a workflow with input parameters.
;;
;; Parameters:
;;   manager: A manager object (e.g., claim-manager-wf2, claim-manager-wf3)
;;   inputs: Map of input parameters (will be passed as chresp to init handler)
;;   entity-id: (optional) If provided, uses existing entity; otherwise creates new one
;;
;; Returns:
;;   Map with:
;;     - "claim_id": The entity's ID
;;     - "state": The current state after processing
;;
;; Example:
;;   ;; Create new entity and start workflow
;;   (invoke-workflow claim-manager-wf2 (sorted-map "policy_id" "POL123" "gw_claim_id" "GW456"))
;;
;;   ;; Continue existing entity workflow
;;   (invoke-workflow claim-manager-wf2 (sorted-map "new_data" "value") "existing-claim-id")
(defun invoke-workflow (manager inputs &optional entity-id)
  (cc:infof (sorted-map "inputs" inputs "entity-id" entity-id) "invoke-workflow called")
  (let* ([entity-id (or entity-id
                        (let* ([new-entity (new-connector-object manager)])
                          (cc:infof (sorted-map "new-entity" new-entity) "created new entity")
                          (get new-entity "claim_id")))])
    (cc:infof (sorted-map "entity-id" entity-id) "triggering workflow")
    ;; Trigger the workflow with the input parameters
    ;; trigger-connector-object returns the updated entity from do-transition
    (let* ([updated-entity (trigger-connector-object manager entity-id inputs)]
           [current-state (get updated-entity "state")])
      (cc:infof (sorted-map "entity-id" entity-id "state" current-state) "workflow triggered")
      (sorted-map
        "claim_id" entity-id
        "state"    current-state))))



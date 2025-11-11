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
;; 'from-name' is the name of the current workflow (e.g., "wf2")
;; 'entity' is the current entity state
;; 'parsed' is the parsed response from the current state handler
;; Returns the claim_id of the newly created workflow object.
; (defun handoff-to-next (from-name entity parsed)
;   (let* ([entry (lookup-next-workflow from-name)]
;          [projector (and entry (get entry :projector))]
;          [next-manager (and entry (get entry :next-manager))])
;     (when (nil? entry)
;       (set-exception-business
;         (format-string "No chained workflow registered for {}" from-name)))
;     (when (nil? projector)
;       (set-exception-business
;         (format-string "Chained workflow {} has no projector function" from-name)))
;     (when (nil? next-manager)
;       (set-exception-business
;         (format-string "Chained workflow {} has no next-manager" from-name)))
    
;     ;; Build the chresp for the next workflow using the projector
;     (let* ([chresp (projector entity parsed)])
;       (when (nil? chresp)
;         (set-exception-business
;           (format-string "Chained projector returned nil for {}" from-name)))
      
;       ;; Invoke the next workflow using the projected inputs
;       ;; This uses invoke-workflow which handles entity creation and triggering
;       (let* ([next-workflow-name (get entry :next-name)]
;              [result (invoke-workflow next-manager chresp)])
;         (cc:infof
;           (sorted-map
;             "from_workflow" from-name
;             "to_workflow" next-workflow-name
;             "next_claim_id" (get result "claim_id")
;             "next_state" (get result "state"))
;           "Handed off to next workflow")
;         (get result "claim_id"))))

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
  (let* ([entity-id (or entity-id
                        (let* ([new-entity (new-connector-object manager)])
                          (get new-entity "claim_id")))])
    ;; Trigger the workflow with the input parameters
    ;; trigger-connector-object returns the updated entity from do-transition
    (let* ([updated-entity (trigger-connector-object manager entity-id inputs)]
           [current-state (get updated-entity "state")])
      (sorted-map
        "claim_id" entity-id
        "state"    current-state))))


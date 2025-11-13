(in-package 'cdcs)

;; ============================================================================
;; Workflow Registration and Completion Infrastructure
;; ============================================================================

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
    ((equal? entity-name "claim_wf1") "wf1")
    ((equal? entity-name "claim_wf2") "wf2")
    ((equal? entity-name "claim_wf3") "wf3")
    ((equal? entity-name "claim_wf4") "wf4")
    ((equal? entity-name "claim_wf5") "wf5")
    (:else nil)))

;; Notify all completion listeners that a workflow has completed.
;; This is called from the done state handler.
;; 'workflow-name' is the name of the workflow (e.g., "wf2", "wf3")
;; 'entity' is the entity that completed
(export 'notify-workflow-completion)
(defun notify-workflow-completion (workflow-name entity)
  (cc:infof
    (sorted-map
      "workflow" workflow-name
      "claim_id" (get entity "claim_id")
      "state" (get entity "state"))
    (format-string "{} workflow completed - invoking completion hooks" workflow-name))
  (let* ([listener (get workflow-completion-listeners workflow-name)])
    (when listener
      (cc:infof (sorted-map
                  "workflow" workflow-name
                  "claim_id" (get entity "claim_id"))
                "Invoking completion listener")
      (listener workflow-name entity))))

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



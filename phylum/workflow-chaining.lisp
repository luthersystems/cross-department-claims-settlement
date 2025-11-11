(in-package 'sandbox)

;; ============================================================================
;; Workflow Chaining Infrastructure
;; ============================================================================
;; Allows workflows to automatically hand off to the next workflow in a chain
;; by registering workflow transitions and projection functions.

;; Global registry: maps workflow name -> (sorted-map :next-name :projector :next-manager)
(set 'workflow-chain-registry (sorted-map))

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
(defun handoff-to-next (from-name entity parsed)
  (let* ([entry (lookup-next-workflow from-name)]
         [projector (and entry (get entry :projector))]
         [next-manager (and entry (get entry :next-manager))])
    (when (nil? entry)
      (set-exception-business
        (format-string "No chained workflow registered for {}" from-name)))
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
      
      ;; Create a new connector object for the next workflow
      ;; Option: reuse claim_id by using (get entity "claim_id") instead
      (let* ([next-obj (new-connector-object next-manager)]
             [next-id (get next-obj "claim_id")])
        (cc:infof
          (sorted-map
            "from_workflow" from-name
            "to_workflow" (get entry :next-name)
            "next_claim_id" next-id
            "chresp" chresp)
          "Handing off to next workflow")
        (trigger-connector-object next-manager next-id chresp)
        next-id))))


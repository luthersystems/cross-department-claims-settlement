;; Copyright © 2025 Luther Systems, Ltd. All right reserved.
;; ----------------------------------------------------------------------------
;; This file is the entrypoint for your operations script.  It should
;; initialize global variables and load files containing utilities and endpoint
;; definitions.  Be careful not to use methods in the cc: package namespace
;; while main.lisp is loading because there is no transaction context until the
;; endpoint handler fires.
;; ----------------------------------------------------------------------------
(in-package 'sandbox)
(use-package 'router)
(use-package 'utils)

;; service-name can be used to identify the service in health checks and longs.
(set 'service-name "sandbox")

;; Set during build process to reflect current version and build ID.
;; Used in health check endpoint for visibility.
(set 'version "LUTHER_PROJECT_VERSION")  ; overridden during build
(set 'build-id "LUTHER_PROJECT_BUILD_ID")  ; overridden during build
(set 'service-version (format-string "{} ({})" version build-id))

;; Load all route definitions and core business logic for this phylum.
(load-file "routes.lisp")
; (load-file "claim.lisp")

(load-file "substr_connector.lisp")
(load-file "substr_generic_state_machine.lisp")
(load-file "substr_ephemeral_storage.lisp")
(load-file "substr_generic_parser.lisp")
(load-file "workflow-config.lisp")      ; Shared workflow chaining config & helpers
(load-file "workflow-chaining.lisp")  ; Load before workflow registrations so invoke-workflow is available
(load-file "01-constants.lisp")        ; Load constants before workflows and routes
(load-file "02-constants.lisp")
(load-file "03-constants.lisp")
(load-file "04-constants.lisp")
(load-file "05-constants.lisp")
(load-file "01-workflow.lisp")
(load-file "01-routes.lisp")
(load-file "02-routes.lisp")
(load-file "02-workflow.lisp")
(load-file "02-helpers.lisp")
(load-file "03-routes.lisp")
(load-file "03-helpers.lisp")
(load-file "03-workflow.lisp")
(load-file "04-workflow.lisp")
(load-file "04-routes.lisp")
(load-file "05-workflow.lisp")
(load-file "05-routes.lisp")
; (load-file "05-state-reg.lisp")
(load-file "workflow-reg.lisp")     ; Registers managers after handlers are defined


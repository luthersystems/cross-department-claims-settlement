;; Copyright © 2025 Luther Systems, Ltd. All right reserved.
;; ----------------------------------------------------------------------------
;; This file is the entrypoint for your operations script.  It should
;; initialize global variables and load files containing utilities and endpoint
;; definitions.  Be careful not to use methods in the cc: package namespace
;; while main.lisp is loading because there is no transaction context until the
;; endpoint handler fires.
;; ----------------------------------------------------------------------------
(in-package 'cdcs)
(use-package 'router)
(use-package 'utils)

;; service-name can be used to identify the service in health checks and longs.
(set 'service-name "cdcs")

;; Set during build process to reflect current version and build ID.
;; Used in health check endpoint for visibility.
(set 'version "LUTHER_PROJECT_VERSION")  ; overridden during build
(set 'build-id "LUTHER_PROJECT_BUILD_ID")  ; overridden during build
(set 'service-version (format-string "{} ({})" version build-id))

;; Load all route definitions and core business logic for this phylum.
(load-file "routes.lisp")

;; Load substrate framework files
(load-file "substrate/substr_connector.lisp")
(load-file "substrate/substr_generic_state_machine.lisp")
(load-file "substrate/substr_ephemeral_storage.lisp")
(load-file "substrate/substr_generic_parser.lisp")

;; Load workflow infrastructure
(load-file "workflow-chaining.lisp")  ; Load before workflow registrations so invoke-workflow is available

;; Load workflow-1 files
(load-file "workflow-1/01-constants.lisp")
(load-file "workflow-1/01-parsers.lisp")     ; Parsing & event creation
(load-file "workflow-1/01-workflow.lisp")
(load-file "workflow-1/01-routes.lisp")
(load-file "workflow-1/01-reg.lisp")         ; Register WF1 manager

;; Load workflow-2 files
(load-file "workflow-2/02-constants.lisp")
(load-file "workflow-2/02-parsers.lisp")     ; Parsing & event creation
(load-file "workflow-2/02-workflow.lisp")
(load-file "workflow-2/02-routes.lisp")
(load-file "workflow-2/02-reg.lisp")         ; Register WF2 manager

;; Load workflow-3 files
(load-file "workflow-3/03-constants.lisp")
(load-file "workflow-3/03-parsers.lisp")     ; Parsing & event creation
(load-file "workflow-3/03-workflow.lisp")
(load-file "workflow-3/03-routes.lisp")
(load-file "workflow-3/03-reg.lisp")         ; Register WF3 manager

;; Load workflow-4 files (workflow-4-edit replaces workflow-4)
(load-file "workflow-4-edit/04-constants.lisp")
(load-file "workflow-4-edit/04-parsers.lisp")     ; Parsing & event creation
(load-file "workflow-4-edit/04-workflow.lisp")
(load-file "workflow-4-edit/04-routes.lisp")
(load-file "workflow-4-edit/04-reg.lisp")         ; Register WF4 manager (workflow-4-edit)

;; Load workflow-5 files
(load-file "workflow-5/05-constants.lisp")
(load-file "workflow-5/05-parsers.lisp")     ; Parsing & event creation
(load-file "workflow-5/05-workflow.lisp")
(load-file "workflow-5/05-routes.lisp")
(load-file "workflow-5/05-reg.lisp")         ; Register WF5 manager

;; Load unified process registration (requires all workflow specs to be loaded)
(load-file "process-routes.lisp")          ; Unified process endpoint
(load-file "process-reg.lisp")        ; Register unified process manager

;; Note: Test files (*_test.lisp) are automatically discovered and loaded by the test runner
;; They should NOT be loaded here to avoid duplicate test registration


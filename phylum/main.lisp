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

;; init and healthcheck.
(load-file "routes.lisp")

;; The claim process: its steps, then the flow that runs them.
(load-file "claim-steps.lisp")
(load-file "claim.lisp")

;; Note: Test files (*_test.lisp) are automatically discovered and loaded by the test runner
;; They should NOT be loaded here to avoid duplicate test registration

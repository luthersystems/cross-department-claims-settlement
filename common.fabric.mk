# This makefile provides targets for local fabric (distributed systems) 
# networks. It's meant to be re-usable across projects.
include ${PROJECT_REL_DIR}/common.mk

# name of the chaincode
CC_NAME ?= com_luthersystems_chaincode_substrate01
# name of the chaincode package to install
CC_PKG_NAME ?= com_luthersystems_chaincode_substrate01
CC_FILE=${CC_PKG_NAME}-${CC_VERSION}.tar.gz
CC_PATH=chaincodes/${CC_FILE}
# path within cli docker container of chaincode
CC_MOUNT_PATH=/chaincodes/${CC_FILE}

PHYLUM_VERSION_FILE=./build/phylum_version

# DOCKER_CHOWN_USER differs from CHOWN_USER because DOCKER_CHOWN_USER needs to
# use identifier numbers (insider docker there is no user defined with the
# proper name).
DOCKER_CHOWN_USER ?= $(shell id -u ${USER}):$(shell id -g ${USER})

# NETWORK_BUILDER is the entrypoint into the NETWORK_BUILDER_IMAGE for all
# commands.
NETWORK_BUILDER_IMAGE ?= luthersystems/fabric-network-builder
NETWORK_BUILDER_TARGET ?= docker-pull/${NETWORK_BUILDER_IMAGE}\:${NETWORK_BUILDER_VERSION}
NETWORK_BUILDER=${NETWORK_BUILDER_IMAGE}:${NETWORK_BUILDER_VERSION} --chown "${DOCKER_CHOWN_USER}"

SHIROCLIENT_IMAGE ?= luthersystems/shiroclient
# Override CONNECTORHUB_IMAGE from common.mk to use the full Docker Hub path
CONNECTORHUB_IMAGE = luthersystems/connectorhub-local

# CONNECTORHUB_REPO is the path to the ConnectorHub repository for local builds.
# Default assumes it's a sibling directory to the project root.
# When PROJECT_REL_DIR=.. (running from fabric/), this resolves to ../../connectorhub
# Override if your ConnectorHub repo is elsewhere:
#   make CONNECTORHUB_REPO=/path/to/connectorhub build-connectorhub-local
CONNECTORHUB_REPO ?= ${PROJECT_REL_DIR}/../connectorhub

SHIROCLIENT_TARGET ?= docker-pull/${SHIROCLIENT_IMAGE}\:${SHIROCLIENT_VERSION}

# CONNECTORHUB_TARGET controls how the ConnectorHub image is obtained.
# By default, it tries to pull from Docker Hub, then falls back to building locally.
# 
# Usage Options:
#
# 1. Use pushed image from Docker Hub (default, automatic):
#    make up
#    # Automatically pulls luthersystems/connectorhub-local:${CONNECTORHUB_VERSION}
#    # If not found, automatically builds from ${CONNECTORHUB_REPO}
#
# 2. Force local build (skip Docker Hub pull):
#    make build-connectorhub-local
#    make up
#    # Builds from source, then uses the locally built image
#
# 3. Use a different image/tag:
#    make CONNECTORHUB_IMAGE=myregistry/connectorhub-local CONNECTORHUB_VERSION=v1.2.3 up
#    # Uses your custom image and version
#
# 4. Use a different local repo path:
#    make CONNECTORHUB_REPO=/custom/path/to/connectorhub build-connectorhub-local
#    # Builds from a custom location
#
# When to use local vs pushed:
# - Pushed: Use for stable releases, CI/CD, or when you don't have the source
# - Local: Use when developing ConnectorHub changes, testing unreleased features,
#          or when you need to modify ConnectorHub behavior
CONNECTORHUB_TARGET ?= docker-pull-connectorhub

SHIROCLIENT_FABRIC_CONFIG_BASENAME=shiroclient
SHIROCLIENT_FABRIC_CONFIG_FAST_BASENAME=shiroclient_fast
# index.gateway_name[.msp_filter]...
PHYLA_GO ?=
CHAINCODE_GO ?= ${PHYLA_GO}
PHYLA_CCAAS ?=
PHYLA ?= ${PHYLA_GO} ${PHYLA_CCAAS}
GATEWAYS ?= 1.shiroclient_gw_a.a
CONNECTORHUBS ?= 1.connectorhub_a.a
START_GATEWAYS=$(addprefix start-gw-,${GATEWAYS})
START_CONNECTORHUBS=$(addprefix start-ch-,${CONNECTORHUBS})
# possibly this
NOTIFY_GATEWAYS=$(addprefix notify-gw-,${GATEWAYS})
FUNCTIONAL_TEST_PHYLA=$(addprefix functional-test-phylum-,${PHYLA})
SHIRO_INIT_PHYLA=$(addprefix shiro-init-phylum-,${PHYLA})
CHANNEL ?= luther
GENERATE_OPTS ?= --domain ${FABRIC_DOMAIN} --org-count=2 --peer-count=2
FABRIC_ORG ?= org1
FABRIC_DOMAIN ?= luther.systems

FABRIC_IMAGE_NAMES=peer orderer ccenv
FABRIC_IMAGE_NS=hyperledger
FABRIC_IMAGE_FQNS=$(patsubst %,${FABRIC_IMAGE_NS}/fabric-%,${FABRIC_IMAGE_NAMES})
FABRIC_CA_IMAGE_FQN=${FABRIC_IMAGE_NS}/fabric-ca
DBMODE ?= goleveldb

FABRIC_IMAGES=$(foreach fqn,${FABRIC_IMAGE_FQNS},${fqn}\:${FABRIC_IMAGE_TAG}) \
              ${FABRIC_CA_IMAGE_FQN}\:${FABRIC_CA_IMAGE_TAG}
FABRIC_IMAGE_TARGETS=$(addprefix docker-pull/,${FABRIC_IMAGES})

FABRIC_DOCKER_NETWORK=byfn

DOCKER_FABRIC_OPTS ?= -e SHIROCLIENT_CLIENT_DEMO_MODE=true

.PHONY: default
default: images
	@

.PHONY: images
images: ${FABRIC_IMAGE_TARGETS} ${SHIROCLIENT_TARGET} ${NETWORK_BUILDER_TARGET} ${CONNECTORHUB_TARGET}
	@

.PHONY: clean-chaincodes
clean-chaincodes:
	rm -rf chaincodes/*.{tar.gz,id} .env

.PHONY: clean
clean: clean-chaincodes
	rm -rf build

.PHONY: pristine
pristine: clean clean-generated

.PHONY: clean-generated
clean-generated:
	rm -rf \
		base \
		channel-artifacts \
		configtx.yaml \
		couchdb \
		crypto-config \
		crypto-config.yaml \
		docker-compose-cli.yaml \
		docker-compose-couch.yaml \
		docker-compose-e2e-template.yaml \
		docker-compose-e2e.yaml \
		fabric-client.yaml \
		fabric-client_fast.yaml \
		fabric-client_template.yaml \
		shiroclient.yaml \
		shiroclient_fast.yaml \
		scripts

.PHONY: go-test
go-test:
	go test -race -cover -v ./...
	$(MAKE) functional-tests

.PHONY: functional-tests
functional-tests: ${FUNCTIONAL_TEST_PHYLA}

functional-test-phylum-%: compile-phylum-%
	# NOTE: shirotester path must be relative to properly work within docker container.
	go run ${PROJECT_REL_DIR}/cmd/shirotester/main.go functional-tests --verbose phylum_$*/testfixtures/*.yaml

.PHONY: generate
generate: ${NETWORK_BUILDER_TARGET}
	rm -rf ./crypto-config ./channel-artifacts
	${DOCKER_RUN} -t \
		${DOCKER_IN_DOCKER_MOUNT} \
		-v "${CURDIR}:${CURDIR}" \
		-w "${CURDIR}" \
		${NETWORK_BUILDER} --channel ${CHANNEL} --force generate \
			--domain=${FABRIC_DOMAIN} \
			--cc-name="${CC_NAME}" \
			${GENERATE_OPTS}

.PHONY: generate-template
generate-template: ${NETWORK_BUILDER_TARGET}
	rm -rf ./crypto-config ./channel-artifacts
	${DOCKER_RUN} -t \
		${DOCKER_IN_DOCKER_MOUNT} \
		-v "${CURDIR}:${CURDIR}" \
		-w "${CURDIR}" \
		${NETWORK_BUILDER} --channel ${CHANNEL} --force generate \
			--domain=${FABRIC_DOMAIN} \
			--cc-name="${CC_NAME}" \
			${GENERATE_OPTS} --template

.PHONY: generate-assets
generate-assets: channel-artifacts/genesis.block

channel-artifacts/genesis.block: ${NETWORK_BUILDER_TARGET}
	rm -rf ./crypto-config ./channel-artifacts
	${DOCKER_RUN} -t \
		${DOCKER_IN_DOCKER_MOUNT} \
		-v "${CURDIR}:${CURDIR}" \
		-w "${CURDIR}" \
		${NETWORK_BUILDER} --channel ${CHANNEL} --force generate \
			--domain=${FABRIC_DOMAIN} \
			--cc-name="${CC_NAME}" \
			${GENERATE_OPTS} --no-template

.PHONY: couchdb-up
couchdb-up: DBMODE = couchdb
couchdb-up: fnb-up gateway-up

.PHONY: up
up: generate-chaincodes .env fnb-up gateway-up connectorhub-up

.PHONY: fnb-up
fnb-up: ${NETWORK_BUILDER_TARGET} ${FABRIC_IMAGE_TARGETS}
	${DOCKER_RUN} -t \
		${DOCKER_IN_DOCKER_MOUNT} \
		-v "${CURDIR}:${CURDIR}" \
		-w "${CURDIR}" \
		-e FABRIC_LOGGING_SPEC \
		-e CHAINCODE_LOG_LEVEL \
		-e CHAINCODE_OTLP_TRACER_ENDPOINT \
		${NETWORK_BUILDER} --channel ${CHANNEL} --force -s "${DBMODE}" up \
			--log-spec debug \
			--cc-version "${CC_VERSION}"

.PHONY: fnb-extend
fnb-extend: ${NETWORK_BUILDER_TARGET} ${FABRIC_IMAGE_TARGETS}
	${DOCKER_RUN} -t \
		${DOCKER_IN_DOCKER_MOUNT} \
		-v "${CURDIR}:${CURDIR}" \
		-w "${CURDIR}" \
		-e FABRIC_LOGGING_SPEC \
		${NETWORK_BUILDER} --channel ${CHANNEL} --force -s "${DBMODE}" extend \
			--domain-name=${FABRIC_DOMAIN}

.PHONY: fnb-shell
fnb-shell: ${NETWORK_BUILDER_TARGET} ${FABRIC_IMAGE_TARGETS}
	${DOCKER_RUN} -t \
		${DOCKER_IN_DOCKER_MOUNT} \
		-v "${CURDIR}:${CURDIR}" \
		-w "${CURDIR}" \
		-e FABRIC_LOGGING_SPEC \
		-e CHANNEL=${CHANNEL} \
		-e FABRIC_DOMAIN=${FABRIC_DOMAIN} \
		-e FABRIC_DBMODE="${DBMODE}" \
		--entrypoint bash \
		${NETWORK_BUILDER_IMAGE}:${NETWORK_BUILDER_VERSION}

.PHONY: gateway-up
gateway-up: ${START_GATEWAYS}

start-gw-%: parts=$(subst ., ,$*)
start-gw-%: idx=$(word 1,${parts})
start-gw-%: name=$(word 2,${parts})
start-gw-%: ccname=$(word 3,${parts})
start-gw-%: filter=$(word 4,${parts})
start-gw-%: port=$$(( 8081 + ${idx} ))
start-gw-%: metrics_port=$$(( 9601 + ${idx} ))
start-gw-%: filter_args=$(if ${filter},-f ${filter})
ifdef EXPOSE_GATEWAY
start-gw-%: port_fw=-p "${port}:${port}"
endif
start-gw-%: ${SHIROCLIENT_TARGET} build/volume/msp build/volume/enroll_user
	${DOCKER_RUN} -d --name ${name} \
		-v "$(abspath build/volume/msp):/tmp/msp:rw" \
		-v "$(abspath build/volume/enroll_user):/tmp/state-store:rw" \
		-v "${CURDIR}:/tmp/fabric:ro" \
		${DOCKER_FABRIC_OPTS} \
		-w "/tmp/fabric" \
		-e ORG="${FABRIC_ORG}" \
		-e DOMAIN_NAME="${FABRIC_DOMAIN}" \
		-e SHIROCLIENT_GATEWAY_OTLP_TRACER_ENDPOINT \
		${port_fw} \
		--network ${FABRIC_DOCKER_NETWORK} \
		${SHIROCLIENT_IMAGE}:${SHIROCLIENT_VERSION} -v \
			--config ${SHIROCLIENT_FABRIC_CONFIG_FAST_BASENAME}_${ccname}.yaml \
			--chaincode.version ${CC_VERSION}_${ccname} \
			gateway ${filter_args}

# docker-pull-connectorhub: Attempts to pull ConnectorHub image from Docker Hub.
# If the image doesn't exist locally or on Docker Hub, automatically falls back
# to building from source using build-connectorhub-local.
#
# Set SKIP_CONNECTORHUB_LOCAL_BUILD=1 to skip the local build fallback (useful in CI).
# This is the default behavior - you typically don't need to call this directly.
# It's automatically invoked when you run targets that need ConnectorHub.
.PHONY: docker-pull-connectorhub
docker-pull-connectorhub:
	@echo "📥 Pulling connectorhub-local from Docker Hub..."
	@docker image inspect ${CONNECTORHUB_IMAGE}:${CONNECTORHUB_VERSION} >/dev/null 2>&1 || \
		(docker pull ${CONNECTORHUB_IMAGE}:${CONNECTORHUB_VERSION} || \
		 (if [ -z "$$SKIP_CONNECTORHUB_LOCAL_BUILD" ]; then \
			echo "⚠️  Image not found on Docker Hub, building from source..." && \
			$(MAKE) build-connectorhub-local; \
		  else \
			echo "❌ Image ${CONNECTORHUB_IMAGE}:${CONNECTORHUB_VERSION} not found and SKIP_CONNECTORHUB_LOCAL_BUILD is set"; \
			exit 1; \
		  fi))

# build-connectorhub-local: Builds ConnectorHub image from source.
# Requires the ConnectorHub repository to be available at ${CONNECTORHUB_REPO}.
#
# Usage:
#   # Build with default repo path (../connectorhub relative to project root)
#   make build-connectorhub-local
#
#   # Build with custom repo path
#   make CONNECTORHUB_REPO=/path/to/connectorhub build-connectorhub-local
#
#   # Build with custom image name/version
#   make CONNECTORHUB_IMAGE=myregistry/connectorhub-local CONNECTORHUB_VERSION=dev build-connectorhub-local
#
# The build uses Dockerfile.local in the ConnectorHub repository root.
# If the image already exists locally, this target will skip the build.
.PHONY: build-connectorhub-local
build-connectorhub-local:
	@connectorhub_repo="$(abspath ${CONNECTORHUB_REPO})"; \
	if [ ! -d "$$connectorhub_repo" ]; then \
		echo "❌ ConnectorHub repository not found at $$connectorhub_repo"; \
		echo "💡 Expected location: $$connectorhub_repo"; \
		echo "💡 Please clone it: git clone https://github.com/luthersystems/connectorhub.git $$connectorhub_repo"; \
		echo "💡 Or override the path: make CONNECTORHUB_REPO=/path/to/connectorhub build-connectorhub-local"; \
		exit 1; \
	fi
	@connectorhub_repo="$(abspath ${CONNECTORHUB_REPO})"; \
	echo "🔨 Building connectorhub-local from $$connectorhub_repo..."; \
	docker image inspect ${CONNECTORHUB_IMAGE}:${CONNECTORHUB_VERSION} >/dev/null 2>&1 || \
		(cd "$$connectorhub_repo" && docker build -f Dockerfile.local -t ${CONNECTORHUB_IMAGE}:${CONNECTORHUB_VERSION} .)
	@echo "✅ connectorhub-local image is ready"

.PHONY: connectorhub-up
connectorhub-up: ${START_CONNECTORHUBS}

# Test a specific connector (e.g., make test-connector c=SHAREPOINT)
.PHONY: test-connector
test-connector: ${CONNECTORHUB_TARGET} build/volume/checkpoint
	@if [ -z "$(c)" ]; then \
		echo "❌ Error: Please specify a connector name with c=CONNECTOR_NAME"; \
		echo "Example: make test-connector c=SHAREPOINT"; \
		exit 1; \
	fi
	@env_file="${PROJECT_ABS_DIR}/.env"; \
	connectorhub_env="${PROJECT_ABS_DIR}/fabric/connectorhub.env"; \
	env_file_flag=""; \
	mock_all_flag="-e MOCK_ALL=${MOCK_ALL}"; \
	if [ -f "$$env_file" ]; then \
		env_file_flag="--env-file $$env_file"; \
		if grep -q "^MOCK_ALL=" "$$env_file" 2>/dev/null; then \
			mock_all_flag=""; \
		fi; \
	fi; \
	if [ -f "$$connectorhub_env" ]; then \
		env_file_flag="$$env_file_flag --env-file $$connectorhub_env"; \
	fi; \
	${DOCKER_RUN} --rm -t \
		-v "${CURDIR}:/tmp/fabric:ro" \
		-v "${PROJECT_ABS_DIR}:/tmp/project:ro" \
		-v "$(abspath build/volume/checkpoint):/tmp/checkpoint:rw" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v /tmp:/tmp \
		-w "/tmp/fabric" \
		${CONNECTORHUB_ENV_VARS} \
		$$env_file_flag \
		$$mock_all_flag \
		--network ${FABRIC_DOCKER_NETWORK} \
		${CONNECTORHUB_IMAGE}:${CONNECTORHUB_VERSION} \
			test -v \
			--config-file /tmp/fabric/connectorhub.yaml \
			--keep-containers \
			--mcp-init-timeout 120 \
			$(c)

# Test a specific connector with a custom tool call and request
# Usage: make test-request c=TEAMS r='{"generic":{"kind":"KIND_MICROSOFT_TEAMS","operation":"start_thread","arguments":{"title":"Test","content":"Test content"}}}'
# Note: The request must be wrapped in {"generic": {...}} with "kind", "operation", and "arguments" fields.
# Examples:
#   Teams: make test-request c=TEAMS r='{"generic":{"kind":"KIND_MICROSOFT_TEAMS","operation":"start_thread","arguments":{"title":"Test","content":"Content"}}}'
#   Salesforce: make test-request c=SALESFORCE r='{"generic":{"kind":"KIND_SALESFORCE","operation":"create_record","arguments":{"object_name":"Task","data":{...}}}}'
.PHONY: test-request
test-request: ${CONNECTORHUB_TARGET} build/volume/checkpoint
	@if [ -z "$(c)" ]; then \
		echo "❌ Error: Please specify a connector name with c=CONNECTOR_NAME"; \
		echo "Example: make test-request c=TEAMS r='{\"generic\":{\"kind\":\"KIND_MICROSOFT_TEAMS\",\"operation\":\"start_thread\",\"arguments\":{...}}}'"; \
		exit 1; \
	fi
	@if [ -z "$(r)" ]; then \
		echo "❌ Error: Please specify a request with r=REQUEST_JSON"; \
		echo "Example: make test-request c=TEAMS r='{\"generic\":{\"kind\":\"KIND_MICROSOFT_TEAMS\",\"operation\":\"start_thread\",\"arguments\":{...}}}'"; \
		exit 1; \
	fi
	@env_file="${PROJECT_ABS_DIR}/.env"; \
	connectorhub_env="${PROJECT_ABS_DIR}/fabric/connectorhub.env"; \
	env_file_flag=""; \
	mock_all_flag="-e MOCK_ALL=${MOCK_ALL}"; \
	if [ -f "$$env_file" ]; then \
		env_file_flag="--env-file $$env_file"; \
		if grep -q "^MOCK_ALL=" "$$env_file" 2>/dev/null; then \
			mock_all_flag=""; \
		fi; \
	fi; \
	if [ -f "$$connectorhub_env" ]; then \
		env_file_flag="$$env_file_flag --env-file $$connectorhub_env"; \
	fi; \
	${DOCKER_RUN} --rm -t \
		-v "${CURDIR}:/tmp/fabric:ro" \
		-v "${PROJECT_ABS_DIR}:/tmp/project:ro" \
		-v "$(abspath build/volume/checkpoint):/tmp/checkpoint:rw" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v /tmp:/tmp \
		-w "/tmp/fabric" \
		${CONNECTORHUB_ENV_VARS} \
		$$env_file_flag \
		$$mock_all_flag \
		--network ${FABRIC_DOCKER_NETWORK} \
		${CONNECTORHUB_IMAGE}:${CONNECTORHUB_VERSION} \
			test-request -v \
			--config-file /tmp/fabric/connectorhub.yaml \
			--keep-containers \
			--request '$(r)' \
			$(c)

# Default connector mock mode setting (can be overridden via .env file or environment)
# Set to "true" to enable mock mode for all connectors, "false" to use real connectors
MOCK_ALL ?= true

# ConnectorHub environment variables with defaults
# Note: MOCK_ALL is conditionally set in the start-ch-% target:
# - If .env file exists and specifies MOCK_ALL, only --env-file is used (no -e flag)
# - If .env file exists but doesn't specify MOCK_ALL, -e MOCK_ALL=${MOCK_ALL} is added before --env-file
# - If .env file doesn't exist, -e MOCK_ALL=${MOCK_ALL} is used
# This ensures .env file can override when specified, but Make default is used otherwise
# LOG_LEVEL can be set to "debug" to enable detailed logging for all connectors (MCP and non-MCP)
# MCP_FULL_LOG can be set to "true" to enable full request/response logging for MCP connectors
# CH_LOG_FULL can be set to "true" to enable full request/response logging for all connectors (including non-MCP like GoCardless)
CONNECTORHUB_ENV_VARS = \
	-e CH_KEEP_CONTAINERS=true \
	$(if $(LOG_LEVEL),-e LOG_LEVEL=$(LOG_LEVEL)) \
	$(if $(MCP_FULL_LOG),-e MCP_FULL_LOG=$(MCP_FULL_LOG)) \
	$(if $(CH_LOG_FULL),-e CH_LOG_FULL=$(CH_LOG_FULL))

start-ch-%: parts=$(subst ., ,$*)
start-ch-%: idx=$(word 1,${parts})
start-ch-%: name=$(word 2,${parts})
start-ch-%: ccname=$(word 3,${parts}) # TODO
start-ch-%: port=$$(( 9091 + ${idx} ))
start-ch-%: port_fw=-p "${port}:8080"
start-ch-%: ${CONNECTORHUB_TARGET} build/volume/checkpoint
	@env_file="${PROJECT_ABS_DIR}/.env"; \
	connectorhub_env="${PROJECT_ABS_DIR}/fabric/connectorhub.env"; \
	env_file_flag=""; \
	mock_all_flag="-e MOCK_ALL=${MOCK_ALL}"; \
	if [ -f "$$env_file" ]; then \
		env_file_flag="--env-file $$env_file"; \
		if grep -q "^MOCK_ALL=" "$$env_file" 2>/dev/null; then \
			mock_all_flag=""; \
		fi; \
	fi; \
	if [ -f "$$connectorhub_env" ]; then \
		env_file_flag="$$env_file_flag --env-file $$connectorhub_env"; \
	fi; \
	${DOCKER_RUN} -d --name ${name} \
		-v "${CURDIR}:/tmp/fabric:ro" \
		-v "${PROJECT_ABS_DIR}:/tmp/project:ro" \
		-v "$(abspath build/volume/checkpoint):/tmp/checkpoint:rw" \
		-v /var/run/docker.sock:/var/run/docker.sock \
  		-v /tmp:/tmp \
		-w "/tmp/fabric" \
		-p "8080:8080" \
		-p "8090:8090" \
		${CONNECTORHUB_ENV_VARS} \
		$$env_file_flag \
		$$mock_all_flag \
		${port_fw} \
		--network ${FABRIC_DOCKER_NETWORK} \
		${CONNECTORHUB_IMAGE}:${CONNECTORHUB_VERSION} \
			start -v \
			--config-file /tmp/fabric/connectorhub.yaml \
			--checkpoint-file /tmp/checkpoint/checkpoint.txt
		
	@echo "⌛ Waiting for ${name} to start..."
	@sleep 3
	@if ! docker ps | grep -q "${name}"; then \
		echo "❌ ConnectorHub ${name} exited unexpectedly!"; \
		echo "🔍 Showing last 50 log lines:"; \
		docker logs --tail 50 ${name} || true; \
		echo ""; \
		echo "💡 Tip: check connectorhub.yaml for invalid keys or indentation"; \
		exit 1; \
	else \
		echo "✅ ConnectorHub ${name} is running successfully."; \
	fi

.SECONDEXPANSION:
notify-gw-%: parts=$(subst ., ,$*)
notify-gw-%: name=$(word 2,${parts})
notify-gw-%: ccname=$(word 3,${parts})
notify-gw-%: ${SHIROCLIENT_TARGET} compile-phylum-$$(ccname) build/volume/msp build/volume/enroll_user ${PHYLUM_VERSION_FILE}
	${DOCKER_RUN} --rm -t \
		-v "$(abspath build/volume/msp):/tmp/msp:rw" \
		-v "$(abspath build/volume/enroll_user):/tmp/state-store:rw" \
		-v "$(abspath build/phylum_${ccname}/phylum.zip):/tmp/phylum.zip:ro" \
		-v "${CURDIR}:/tmp/fabric:ro" \
		${DOCKER_FABRIC_OPTS} \
		-w "/tmp/fabric" \
		-e ORG="${FABRIC_ORG}" \
		-e DOMAIN_NAME="${FABRIC_DOMAIN}" \
		--network ${FABRIC_DOCKER_NETWORK} \
		${SHIROCLIENT_IMAGE}:${SHIROCLIENT_VERSION} -v \
			--config ${SHIROCLIENT_FABRIC_CONFIG_FAST_BASENAME}_${ccname}.yaml \
			--chaincode.version ${CC_VERSION}_${ccname} \
			notify -g http://${name}:8082 "$(shell cat ${PHYLUM_VERSION_FILE})"

.PHONY: couchdb-down
couchdb-down: DBMODE = couchdb
couchdb-down: gateway-down fnb-down

# oracle-up and oracle-down are declared as phony targets so they can be used
# as dependencies and ordered correctly when processing other phony targets.
.PHONY: oracle-up
.PHONY: oracle-down

.PHONY: down
down: oracle-down connectorhub-down gateway-down fnb-down clean

.PHONY: fnb-down
fnb-down: ${NETWORK_BUILDER_TARGET}
	-rm -f "${PHYLUM_VERSION_FILE}"
	-${DOCKER_RUN} -t \
		${DOCKER_IN_DOCKER_MOUNT} \
		-v "${CURDIR}:${CURDIR}" \
		-w "${CURDIR}" \
		-e FABRIC_LOGGING_SPEC \
		${NETWORK_BUILDER} --channel ${CHANNEL} --force -s "${DBMODE}" down

.PHONY: gateway-down
gateway-down: gw_names=$(foreach g,${GATEWAYS},$(word 2,$(subst ., ,${g})))
gateway-down:
	-docker stop ${gw_names}

.PHONY: connectorhub-down
connectorhub-down: ch_names=$(foreach g,${CONNECTORHUBS},$(word 2,$(subst ., ,${g})))
connectorhub-down:
	-docker stop ${ch_names}

.PHONY: sleep-%
sleep-%:
	@sleep $*

.PHONY: install
install: ${NETWORK_BUILDER_TARGET}
	${DOCKER_RUN} -t \
		${DOCKER_IN_DOCKER_MOUNT} \
		-v "${CURDIR}:${CURDIR}" \
		-w "${CURDIR}" \
		-e FABRIC_LOGGING_SPEC \
		${NETWORK_BUILDER} --channel ${CHANNEL} --force install \
			"${CC_NAME}" \
			"${CC_VERSION}" \
			"${PHYLA}" \
			"${CC_MOUNT_PATH}"

.PHONY: generate-chaincode
generate-chaincodes: generate-go-chaincodes generate-ccaas-chaincodes
	@

.PHONY: generate-go-chaincodes
generate-go-chaincodes: ${NETWORK_BUILDER_TARGET}
	${DOCKER_RUN} -t \
		${DOCKER_IN_DOCKER_MOUNT} \
		-v "${CURDIR}:${CURDIR}" \
		-w "${CURDIR}" \
		-e FABRIC_LOGGING_SPEC \
		${NETWORK_BUILDER} --force generatecc \
			"${CC_NAME}" \
			"${CC_VERSION}" \
			"${CHAINCODE_GO}" \
			"${CC_MOUNT_PATH}"

.PHONY: generate-ccaas-chaincodes
generate-ccaas-chaincodes: ${NETWORK_BUILDER_TARGET}
	${DOCKER_RUN} -t \
		${DOCKER_IN_DOCKER_MOUNT} \
		-v "${CURDIR}:${CURDIR}" \
		-w "${CURDIR}" \
		-e FABRIC_LOGGING_SPEC \
		${NETWORK_BUILDER} --force generatecc --ccaas\
			"${CC_NAME}" \
			"${CC_VERSION}" \
			"${PHYLA_CCAAS}" \
			"${CC_MOUNT_PATH}"

.PHONY: ${PHYLUM_VERSION_FILE}
${PHYLUM_VERSION_FILE}:
	date +local-%s >${PHYLUM_VERSION_FILE}

.PHONY: ${PHYLUM_VERSION_FILE}_exists
${PHYLUM_VERSION_FILE}_exists:
	@test -f ${PHYLUM_VERSION_FILE}

.PHONY: init
init: ${SHIRO_INIT_PHYLA} ${NOTIFY_GATEWAYS}

shiro-init-phylum-%: ${SHIROCLIENT_TARGET} compile-phylum-% build/volume/msp build/volume/enroll_user ${PHYLUM_VERSION_FILE}
	${DOCKER_RUN} -t \
		-v "$(abspath build/volume/msp):/tmp/msp:rw" \
		-v "$(abspath build/volume/enroll_user):/tmp/state-store:rw" \
		-v "$(abspath build/phylum_$*/phylum.zip):/tmp/phylum.zip:ro" \
		-v "${CURDIR}:/tmp/fabric:ro" \
		${DOCKER_FABRIC_OPTS} \
		-e ORG="${FABRIC_ORG}" \
		-e DOMAIN_NAME="${FABRIC_DOMAIN}" \
		-w "/tmp/fabric" \
		--network ${FABRIC_DOCKER_NETWORK} \
		${SHIROCLIENT_IMAGE}:${SHIROCLIENT_VERSION} -v \
			--config ${SHIROCLIENT_FABRIC_CONFIG_BASENAME}_$*.yaml \
			--chaincode.version ${CC_VERSION}_$* \
			init "$(shell cat ${PHYLUM_VERSION_FILE})" /tmp/phylum.zip

call_cmd-%:
	@echo ${DOCKER_RUN} \
		-v "$(abspath build/volume/msp):/tmp/msp:rw" \
		-v "$(abspath build/volume/enroll_user):/tmp/state-store:rw" \
		-v "${CURDIR}:/tmp/fabric:ro" \
		${DOCKER_FABRIC_OPTS} \
		-e ORG="${FABRIC_ORG}" \
		-e DOMAIN_NAME="${FABRIC_DOMAIN}" \
		-e SHIROCLIENT_LOG_LEVEL \
		-w "/tmp/fabric" \
		--network ${FABRIC_DOCKER_NETWORK} \
		${SHIROCLIENT_IMAGE}:${SHIROCLIENT_VERSION} \
			--config ${SHIROCLIENT_FABRIC_CONFIG_BASENAME}_$*.yaml \
			--chaincode.version ${CC_VERSION}_$* \
			--phylum.version latest \
			call \
			--seed

enable_logging-%:
	./logging-pbool-ctl.sh true \
		${DOCKER_RUN} \
		-v "$(abspath build/volume/msp):/tmp/msp:rw" \
		-v "$(abspath build/volume/enroll_user):/tmp/state-store:rw" \
		-v "${CURDIR}:/tmp/fabric:ro" \
		${DOCKER_FABRIC_OPTS} \
		-e ORG="${FABRIC_ORG}" \
		-e DOMAIN_NAME="${FABRIC_DOMAIN}" \
		-w "/tmp/fabric" \
		--network ${FABRIC_DOCKER_NETWORK} \
		${SHIROCLIENT_IMAGE}:${SHIROCLIENT_VERSION} -v \
			--config ${SHIROCLIENT_FABRIC_CONFIG_FAST_BASENAME}_$*.yaml \
			--chaincode.version ${CC_VERSION}_$* \
			--phylum.version latest \
			call set_app_control_property

disable_logging-%:
	./logging-pbool-ctl.sh false \
		${DOCKER_RUN} \
		-v "$(abspath build/volume/msp):/tmp/msp:rw" \
		-v "$(abspath build/volume/enroll_user):/tmp/state-store:rw" \
		-v "${CURDIR}:/tmp/fabric:ro" \
		${DOCKER_FABRIC_OPTS} \
		-e ORG="${FABRIC_ORG}" \
		-e DOMAIN_NAME="${FABRIC_DOMAIN}" \
		-w "/tmp/fabric" \
		--network ${FABRIC_DOCKER_NETWORK} \
		${SHIROCLIENT_IMAGE}:${SHIROCLIENT_VERSION} -v \
			--config ${SHIROCLIENT_FABRIC_CONFIG_FAST_BASENAME}_$*.yaml \
			--chaincode.version ${CC_VERSION}_$* \
			--phylum.version latest \
			call set_app_control_property

metadump_cmd-%:
	@echo ${DOCKER_RUN} \
		-v "$(abspath build/volume/msp):/tmp/msp:rw" \
		-v "$(abspath build/volume/enroll_user):/tmp/state-store:rw" \
		-v "${CURDIR}:/tmp/fabric:ro" \
		${DOCKER_FABRIC_OPTS} \
		-e ORG="${FABRIC_ORG}" \
		-e DOMAIN_NAME="${FABRIC_DOMAIN}" \
		-w "/tmp/fabric" \
		--network ${FABRIC_DOCKER_NETWORK} \
		${SHIROCLIENT_IMAGE}:${SHIROCLIENT_VERSION} -v \
			--config ${SHIROCLIENT_FABRIC_CONFIG_FAST_BASENAME}_$*.yaml \
			--chaincode.version ${CC_VERSION}_$* \
			--phylum.version latest \
			metadump

get_phyla-%:
	${DOCKER_RUN} \
		-v "$(abspath build/volume/msp):/tmp/msp:rw" \
		-v "$(abspath build/volume/enroll_user):/tmp/state-store:rw" \
		-v "${CURDIR}:/tmp/fabric:ro" \
		${DOCKER_FABRIC_OPTS} \
		-e ORG="${FABRIC_ORG}" \
		-e DOMAIN_NAME="${FABRIC_DOMAIN}" \
		-w "/tmp/fabric" \
		--network ${FABRIC_DOCKER_NETWORK} \
		${SHIROCLIENT_IMAGE}:${SHIROCLIENT_VERSION} -v \
			--config ${SHIROCLIENT_FABRIC_CONFIG_FAST_BASENAME}_$*.yaml \
			--chaincode.version ${CC_VERSION}_$* \
			--phylum.version latest \
			call get_phyla '{}'

build/volume/msp:
	mkdir -p $@
	chmod a+w $@

build/volume/enroll_user:
	mkdir -p $@
	chmod a+w $@

build/volume/checkpoint:
	mkdir -p $@
	chmod a+w $@

.SECONDEXPANSION:
compile-phylum-%: $$(shell find -L phylum_$$* -name "*.lisp" -not -path "*/build/*" 2>/dev/null)
	mkdir -p ./build/phylum_$*
	rm -rf   ./build/phylum_$*/src
	mkdir -p ./build/phylum_$*/src
	@for file in $^; do \
		dir=$$(dirname "$$file"); \
		rel_dir=$${dir#phylum_$*/}; \
		rel_dir=$${rel_dir#./}; \
		if [ "$$rel_dir" = "phylum_$*" ] || [ -z "$$rel_dir" ] || [ "$$rel_dir" = "." ]; then \
			cp "$$file" "./build/phylum_$*/src/"; \
		else \
			mkdir -p "./build/phylum_$*/src/$$rel_dir"; \
			cp "$$file" "./build/phylum_$*/src/$$rel_dir/"; \
		fi; \
	done
	cd       ./build/phylum_$*/src && find . -name "*.lisp" -type f | sort && rm -f ./../phylum.zip && cd . && zip -r ./../phylum.zip . -x "*.orig"

chaincodes/:
	mkdir -p chaincodes/

CHAINCODE_ID_FILES := $(wildcard ./chaincodes/*.id)

.env: $(CHAINCODE_ID_FILES)
	@./scripts/env.sh

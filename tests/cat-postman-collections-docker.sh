#!/bin/bash
# Copyright © 2021 Luther Systems, Ltd. All right reserved.

set -e

SCRIPT="${BASH_SOURCE:-$0}"
SOURCE_DIR=$(dirname "$SCRIPT")
PROJECT_DIR=$(cd "${SOURCE_DIR}/.." && pwd)

# Docker image configuration (matching tests/Makefile)
MARTIN_IMAGE="luthersystems/martin"
MARTIN_VERSION="v0.1.0"
MARTIN_BIND_SOURCE="${PROJECT_DIR}"
MARTIN_BIND_DEST="/etc/postman"
MARTIN_BIND="${MARTIN_BIND_SOURCE}:${MARTIN_BIND_DEST}"
MARTIN_COMMON_OPTS="-v ${MARTIN_BIND} -w ${MARTIN_BIND_DEST}/tests --entrypoint sh"

# Construct and run the docker command
docker run --rm -t ${MARTIN_COMMON_OPTS} ${MARTIN_IMAGE}:${MARTIN_VERSION} cat-postman-collections.sh "$@"

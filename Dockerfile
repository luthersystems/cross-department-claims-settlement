# ------------------------------------------------------------------------------
# Dockerfile: Deployment container for the portal service (in ./portal/)
#
# This container builds and serves the compiled binary for the middleware
# API (the "oracle") that exposes the REST/JSON interface.
# ------------------------------------------------------------------------------

# First stage: build the binary using the provided build image
ARG BUILD_IMAGE
ARG SERVICE_BASE_IMAGE

FROM $BUILD_IMAGE AS build

# Copy source code into the build container
COPY . /src
WORKDIR /src

# Build-time arguments
ARG VERSION
ARG GO_BUILD_TAGS
ARG SERVICE_DIR
ARG GONOSUMDB=""
ARG GOPROXY=""
# The build image (BUILDENV_TAG v0.0.92) ships Go 1.24 with GOTOOLCHAIN=local,
# but go.mod needs Go 1.26 for the stdlib security fixes. auto makes go fetch
# the toolchain go.mod names (through GOPROXY). Drop this once BUILDENV_TAG is
# raised to a build image that ships Go 1.26.
ENV GOTOOLCHAIN=auto

# Run build script, which compiles the Go service to /src/app
RUN ["/src/scripts/build.sh"]

# Second stage: production image using a minimal service base
FROM $SERVICE_BASE_IMAGE AS prod

# Copy the compiled binary into the final container
COPY --from=build /src/app /opt/app

# service-base-alpine already runs as nobody; restate it so this file, read
# on its own, says the service does not run as root (Trivy DS-0002), and a
# base that changed its default user could not switch the service silently.
USER nobody

# Entrypoint: run the app using tini for proper signal handling
ENTRYPOINT ["tini", "--", "/opt/app"]
CMD ["start"]

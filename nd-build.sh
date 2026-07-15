#!/usr/bin/env bash
# Run nornir-build inside the Nornir Docker image (cwd mounted at /workspace).
# Usage: ./nd-build.sh [--gpu] [args...]
# Env: NORNIR_DOCKER_IMAGE (default nornir:dev), NORNIR_DOCKER_GPU=1, NORNIR_DOCKER_EXTRA_ARGS (space-separated docker run flags)

set -euo pipefail

IMAGE="${NORNIR_DOCKER_IMAGE:-nornir:dev}"
WORKDIR="$(pwd -P)"
DOCKER_RUN=(docker run --rm -i)
if [ -t 0 ] && [ -t 1 ]; then
  DOCKER_RUN+=(-t)
fi

if [[ "${NORNIR_DOCKER_GPU:-0}" == "1" ]]; then
  DOCKER_RUN+=(--gpus all)
elif [[ "${1:-}" == "--gpu" ]]; then
  DOCKER_RUN+=(--gpus all)
  shift
fi

if [[ -n "${NORNIR_DOCKER_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA=( $NORNIR_DOCKER_EXTRA_ARGS )
  DOCKER_RUN+=("${EXTRA[@]}")
fi

# Publish to the dashboard broker when NORNIR_MQTT_HOST is set. Join the
# dashboard network (default "nornir-docker_default" from compose.dashboard.yaml)
# so the "mosquitto" service name resolves; override with NORNIR_MQTT_NETWORK.
if [[ -n "${NORNIR_MQTT_HOST:-}" ]]; then
  DOCKER_RUN+=(-e "NORNIR_MQTT_HOST=${NORNIR_MQTT_HOST}")
  DOCKER_RUN+=(-e "NORNIR_MQTT_PORT=${NORNIR_MQTT_PORT:-1883}")
  DOCKER_RUN+=(--network "${NORNIR_MQTT_NETWORK:-nornir-docker_default}")
fi

DOCKER_RUN+=(-v "${WORKDIR}:/workspace" -w /workspace "$IMAGE" nornir-build)
DOCKER_RUN+=("$@")

exec "${DOCKER_RUN[@]}"

#!/bin/sh
# Block until the harness mod signals that the world is up, or fail after
# `$1` seconds (default 120).
#
#   docker exec noita /wait-ready.sh [timeout]

set -e

timeout_s=${1:-120}

timeout "$timeout_s" sh -c 'until [ -e /app/world_ready ]; do sleep 0.1; done' || {
    echo "[noita-docker] timed out after ${timeout_s}s waiting for /app/world_ready" >&2
    exit 1
}

#!/bin/sh
# Ask Noita to quit the way a user would (alt+F4) and wait for the process to
# go away, so the game gets a chance to write its save. Fails after `$1`
# seconds (default 10), at which point the caller can fall back to
# `docker stop`.
#
#   docker exec noita /shutdown.sh [timeout] && docker stop noita

set -e

timeout_s=${1:-10}

xdotool search --name Noita key --window %@ alt+F4 2>/dev/null || true

timeout "$timeout_s" sh -c 'while pidof noita.exe >/dev/null 2>&1; do sleep 0.1; done' || {
    echo "[noita-docker] noita.exe still alive after ${timeout_s}s" >&2
    exit 1
}

#!/usr/bin/env bash
# Bake a standalone image with the Noita install inside it, so it runs without
# the `-v <path>:/noita` bind.
#
#   scripts/bake.sh [tag] [path-to-noita]
#
# Env:
#   DOCKER      container engine (default: docker)
#   BASE_IMAGE  image to layer on top of (default: noita-headless)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")

docker=${DOCKER:-docker}
base=${BASE_IMAGE:-noita-headless}

tag=${1:-}
path=${2:-$("$here/locate-noita.sh")}
[[ -n "$tag" ]] || tag="noita-headless:$("$here/noita-version.sh" "$path")"

context=$root/.bake-context
trap 'rm -rf "$context"' EXIT
rm -rf "$context"
mkdir -p "$context"

rsync -a \
    --exclude=tools_modding \
    --exclude=mods \
    --include='Master Bank*.bank' \
    --exclude='*.bank' \
    "$path/" "$context/noita/"

"$docker" build -t "$tag" --build-arg "BASE_IMAGE=$base" -f "$root/Dockerfile.bake" "$context"

echo "baked image: $tag"
echo "run it with: docker run --rm -d --name noita $tag"

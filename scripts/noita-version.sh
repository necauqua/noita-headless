#!/usr/bin/env bash
# Print the build date of a Noita install, scraped out of noita.exe, in a form
# usable as an image tag (e.g. `2024-01-30`).
#
#   scripts/noita-version.sh [path-to-noita]
set -euo pipefail

path=${1:-$("$(dirname "$0")/locate-noita.sh")}

strings "$path/noita.exe" \
    | perl -lne 'print lc($1 =~ s/ /-/gr) if /^Noita - Build (.+?) -/'

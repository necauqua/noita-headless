#!/usr/bin/env bash
# Print the path of a Noita install found in the local Steam library.
set -euo pipefail

vdf="$HOME/.steam/steam/steamapps/libraryfolders.vdf"
[[ ! -f "$vdf" ]] && vdf="$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"

if [[ ! -f "$vdf" ]]; then
    echo "no Steam libraryfolders.vdf found; pass the Noita path explicitly" >&2
    exit 1
fi

found=$(awk -v app="881100" '
/"path"/ {
    gsub(/["\t ]/, "", $2)
    path = $2 "/steamapps"
    if (system("test -d \"" path "\"") == 0) {
        current_path = path
    }
}
current_path && $0 ~ "\"" app "\"" {
    print current_path "/common"
    exit
}' "$vdf")

if [[ -z "$found" ]]; then
    echo "Noita Steam location not found; specify the location manually" >&2
    exit 1
fi

echo "$found/Noita"

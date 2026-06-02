# noita-docker — common operations. Run `just` for the full menu.
#
# Override variables on the CLI:
#   just args="-gamemode 0" start
#   just seed=12345 start
#   just name=test start

# `name` is used as a container name suffix as well as the key for the
# `noita-appdata-<name>` named volume that persists save state.
name := "default"

# Args forwarded to noita.exe
args := "-gamemode -no_logo_splashes"

# Optional world seed
seed := ""

# Set to any non-empty value (e.g. `just vnc=true start`) to run x11vnc inside
# the container and publish 5900 on the host. No auth -- bind locally or tunnel.
vnc := ""

# Derived container name
container := "noita-" + name

# Derived volume name
appdata := "noita-appdata-" + name

@_:
    just -ul

# Build/rebuild the image
build:
    docker build -t noita-headless .

# Start a detached Noita container
@start path=`just locate-noita`:
    docker run --rm -d --name {{container}} \
        -v {{path}}:/noita:ro \
        -v {{justfile_directory()}}/mods:/mods:ro \
        -v {{appdata}}:/appdata \
        {{ if seed != "" { "-e NOITA_WORLD_SEED=" + seed } else { "" } }} \
        {{ if vnc != "" { "-e NOITA_VNC=1 -p localhost:5900:5900" } else { "" } }} \
        noita-headless {{args}}

# Wait until the harness mod signals readiness, or fail after `timeout` seconds
@wait timeout="120":
    timeout {{timeout}} sh -c 'until docker exec {{container}} test -e /app/player_ready 2>/dev/null; do sleep 0.1; done' \
        || { echo "timed out after {{timeout}}s; check 'just logs'" >&2; exit 1; }

# Dump the current frame to `path` (default ./shot.png)
screenshot path="shot.png":
    docker exec {{container}} /screenshot.sh > {{path}}

# Run xdotool in the container (e.g. `just send key Return`)
send +xargs:
    docker exec {{container}} xdotool {{xargs}}

# List running noita containers
@list:
    docker ps --filter ancestor=noita-headless --format "{{ '{{.Names}}\t{{.Status}}' }}"

# Follow the container logs
logs:
    docker logs -f {{container}}

# Gracefully stop the container in a way that allows Noita a chance to write the save
stop timeout="10":
    @-docker exec {{container}} xdotool search --name Noita key --window %@ alt+F4 2>/dev/null
    @timeout {{timeout}} sh -c 'while docker exec {{container}} pidof noita.exe >/dev/null 2>&1; do sleep 0.1; done'
    -docker stop {{container}} 2>/dev/null

# Stop the container and drop its appdata volume
reset: stop
    -docker volume rm {{appdata}} 2>/dev/null

# Bake a standalone image that works without bind mounts
bake tag="" path=`just locate-noita`: build
    rm -rf .bake-context
    mkdir -p .bake-context
    rsync -a \
        --exclude=tools_modding \
        --exclude=mods \
        --include='Master Bank*.bank' \
        --exclude='*.bank' \
        {{path}}/ .bake-context/noita/
    docker build \
        -t {{ if tag != "" { tag } else { "noita-headless:" + `just extract-version-date` } }} \
        -f Dockerfile.bake \
        .bake-context
    rm -rf .bake-context

# Try to find Noita installed in your Steam library
[private]
locate-noita:
    #!/usr/bin/env bash
    set -euo pipefail

    vdf="$HOME/.steam/steam/steamapps/libraryfolders.vdf"
    [[ ! -f "$vdf" ]] && vdf="$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"

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
        echo "Noita Steam location not found; Specify location manually via the path= parameter" >&2
        exit 1
    fi

    echo "$found/Noita"

[private]
@extract-version-date:
    strings "{{ `just locate-noita` }}/noita.exe" \
        | perl -lne 'print lc($1 =~ s/ /-/gr) if /^Noita - Build (.+?) -/'

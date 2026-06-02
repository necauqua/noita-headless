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

# Derived container name
container := "noita-" + name

# Derived volume name
appdata := "noita-appdata-" + name

@_:
    just -ul

# Build/rebuild the image
build:
    docker build -t noita-headless .

# Start Noita detached. Honors `args`, `seed`, and `name`.
@start:
    docker run --rm -d --name {{container}} \
        -v {{justfile_directory()}}/noita:/noita:ro \
        -v {{justfile_directory()}}/mods:/mods:ro \
        -v {{appdata}}:/appdata \
        {{ if seed != "" { "-e NOITA_WORLD_SEED=" + seed } else { "" } }} \
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
stop:
    @-docker exec {{container}} xdotool search --name Noita key --window %@ alt+F4 2>/dev/null
    @timeout 10 sh -c 'while docker exec {{container}} pidof noita.exe >/dev/null 2>&1; do sleep 0.1; done'
    -docker stop {{container}} 2>/dev/null

# Stop the container and drop its appdata volume
clean: stop
    -docker volume rm {{appdata}} 2>/dev/null

# Bake a standalone image that works without bind mounts
bake src="./noita" tag="noita-headless-baked": build
    rm -rf .bake-context
    mkdir -p .bake-context
    rsync -a \
        --exclude=tools_modding \
        --exclude=mods \
        --include='Master Bank*.bank' \
        --exclude='*.bank' \
        {{src}}/ .bake-context/noita/
    docker build -t {{tag}} -f Dockerfile.bake .bake-context
    rm -rf .bake-context

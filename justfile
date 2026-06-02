# noita-docker — common operations. Run `just` for the full menu.
#
# Override variables on the CLI:
#   just args="-gamemode 1" run
#   just seed=12345 start
#   just name=test start

# `name` is used as a container name suffix as well as to persist appdata via
# `noita-appdata-<name>` named volumes
name := "default"

# Args forwarded to noita.exe
args := "-gamemode 0 -no_logo_splashes"

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
    docker compose build

# Start Noita detached. Honors `args`, `seed`, and `name`
start:
    docker compose run --rm -d --name {{container}} \
        -v {{appdata}}:/appdata \
        {{ if seed != "" { "-e NOITA_WORLD_SEED=" + seed } else { "" } }} \
        noita {{args}}

# Wait until the harness mod signals player-spawn, or fail after `timeout` seconds
wait timeout="120":
    @timeout {{timeout}} sh -c 'until docker exec {{container}} test -e /appdata/player_ready 2>/dev/null; do sleep 0.5; done' \
        || { echo "timed out after {{timeout}}s; check 'just logs'" >&2; exit 1; }

# Dump the current frame to `path` (default ./shot.png)
screenshot path="shot.png":
    docker exec {{container}} /screenshot.sh > {{path}}

# Run xdotool in the container (e.g. `just send key Return`)
send +xargs:
    docker exec {{container}} xdotool {{xargs}}

# List running noita containers
list:
    @docker ps --filter ancestor=noita-headless --format "{{ '{{.Names}}\t{{.Status}}' }}"

# Follow the container logs
logs:
    docker logs -f {{container}}

# Stop the container
stop:
    docker stop {{container}}

# Stop the container and drop its appdata volume
clean: stop
    docker volume rm {{appdata}}

# noita-docker — common operations. Run `just --list` for the full menu.
#
# Override variables on the CLI:
#   just args="-gamemode 1" run
#   just seed=12345 start
#   just name=test-noita start

# Container name used by all recipes.
name := "noita"
# Args forwarded to noita.exe. "-gamemode 0" goes straight into New Game.
args := "-gamemode 0 -no_logo_splashes"
# Optional world seed.
seed := ""

@_:
    just -ul

# Build/rebuild the image.
build:
    docker compose build

# Start Noita detached. Honors `args` and `seed` variables.
run:
    docker compose run --rm -d --name {{name}} \
        {{ if seed != "" { "-e NOITA_WORLD_SEED=" + seed } else { "" } }} \
        noita {{args}}

# Block until the harness mod signals player-spawn, or fail after `timeout` seconds.
wait timeout="120":
    @timeout {{timeout}} sh -c 'until [ -e appdata/player_ready ]; do sleep 0.2; done' \
        || { echo "timed out after {{timeout}}s; check 'just logs'" >&2; exit 1; }

# Run Noita and wait for the player to spawn.
start: run wait

# Dump the current frame to `path` (default ./shot.png).
screenshot path="shot.png":
    docker exec {{name}} /screenshot.sh > {{path}}

# Run xdotool in the container (e.g. `just xdotool key Return`).
xdotool +xargs:
    docker exec {{name}} xdotool {{xargs}}

# List running noita containers (anything off the noita-headless image).
list:
    @docker ps --filter ancestor=noita-headless --format "{{ '{{.Names}}\t{{.Status}}' }}"

# Follow the container logs.
logs:
    docker logs -f {{name}}

# Stop the container (no-op if it isn't running).
stop:
    docker stop {{name}}

# Wipe local save state (./appdata).
clean-saves:
    rm -rf appdata && mkdir appdata

# Wipe the wineprefix volume (forces a fresh wineboot on next start).
clean-prefix:
    docker volume rm noita-docker_wineprefix

# Stop the container, wipe saves, wipe wineprefix.
nuke: stop clean-saves clean-prefix

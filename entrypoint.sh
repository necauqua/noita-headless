#!/bin/sh
set -e

log() { echo "[noita-docker] $*"; }

if [ ! -f /noita/noita.exe ]; then
    log "ERROR: /noita does not contain noita.exe. Either:"
    log "  - mount the game folder: docker run -v \"\$PWD/noita:/noita:ro\" ... noita-headless"
    log "  - or use a baked image (built via 'just bake') which doesn't need this mount"
    exit 1
fi

# NOITA_WORLD_SEED is templated into Lua below, so it has to be a plain
# integer. Noita seeds are 1..2^31-1.
if [ -n "${NOITA_WORLD_SEED:-}" ]; then
    case "$NOITA_WORLD_SEED" in
        *[!0-9]*)
            log "ERROR: NOITA_WORLD_SEED must be an integer in 1..2147483647,"
            log "       got '$NOITA_WORLD_SEED'"
            exit 1
            ;;
    esac
    if [ "$NOITA_WORLD_SEED" -lt 1 ] || [ "$NOITA_WORLD_SEED" -gt 2147483647 ]; then
        log "ERROR: NOITA_WORLD_SEED out of range 1..2147483647: $NOITA_WORLD_SEED"
        exit 1
    fi
fi

RESOLUTION=${NOITA_RESOLUTION:-1280x720x24}

log "starting Xvfb on :99 ($RESOLUTION)"
Xvfb :99 -screen 0 "$RESOLUTION" -nolisten tcp &
until [ -S /tmp/.X11-unix/X99 ]; do sleep 0.05; done

# Optional VNC server attached to :99. No password -- expose the port only
# locally or over an SSH tunnel.
if [ -n "$NOITA_VNC" ]; then
    log "starting x11vnc on :5900"
    x11vnc -display :99 -forever -shared -nopw -quiet -rfbport 5900 &
fi

# Point %APPDATA%\..\LocalLow (where Noita stores save data) at /appdata,
# so an optional -v <vol>:/appdata persists saves across container lifecycles.
USER_DIR="$WINEPREFIX/drive_c/users/$(whoami)"
mkdir -p "$USER_DIR/AppData"
if [ ! -L "$USER_DIR/AppData/LocalLow" ]; then
    rm -rf "$USER_DIR/AppData/LocalLow"
    ln -s /appdata "$USER_DIR/AppData/LocalLow"
fi

# Build a writable mirror of /noita at /app using symlinks.
# This lets us edit /app/mods, keeping /noita bind readonly, as well as lets
# Noita itself write to logger.txt etc
log "mirroring /noita -> /app"
rm -rf /app
cp -rs /noita /app

# Files Noita rewrites inside its own install directory would end up as
# symlinks into the read-only bind, so drop them and let the game recreate
# them as real files in the container layer.
rm -f /app/logger.txt /app/player_ready

# Noita shows the "Welcome to Noita Update" popup when _version_hash.txt
# disagrees with config.xml's last_started_game_version_hash. Pin both to a
# constant instead of reading the real hash, so the popup can never show up
# no matter which build is mounted.
VERSION_HASH=static
rm -f /app/_version_hash.txt
printf %s "$VERSION_HASH" > /app/_version_hash.txt

# make sure mods is an empty folder that does exist
rm -rf /app/mods
mkdir -p /app/mods

cp -r /opt/noita-docker-harness /app/mods/
user_mods=0
for src in /mods/*/; do
    [ -d "$src" ] || continue
    ln -sfn "$src" "/app/mods/$(basename "$src")"
    user_mods=$((user_mods + 1))
done
log "mods: harness + $user_mods user mod(s)"

# Pre-seeding save state:

NOITA_DIR=/appdata/Nolla_Games_Noita
if [ -d "$NOITA_DIR/save00/world" ]; then
    log "appdata: prior save present ($(find "$NOITA_DIR/save00/world" -type f 2>/dev/null | wc -l) world files)"
else
    log "appdata: no prior save"
fi
mkdir -p "$NOITA_DIR/save00/persistent/flags" "$NOITA_DIR/save_shared"

# Skip the first-game cutscene.
touch "$NOITA_DIR/save00/persistent/flags/intro_has_played"

# config.xml:
#   last_started_game_version_hash matches the _version_hash.txt written above
#     -> skips the "Welcome to Noita Update" popup
#   mods_sandbox_enabled="0" + dismissed disclaimer flags
#     -> mods get unsandboxed Lua (needed for the harness mod's file signal)
cat > "$NOITA_DIR/save_shared/config.xml" <<EOF
<Config
  config_format_version="14"
  mods_disclaimer_accepted="1"
  mods_sandbox_enabled="0"
  mods_sandbox_warning_done="1"
  last_started_game_version_hash="$VERSION_HASH"
/>
EOF

# Auto-enable every mod under /app/mods (the harness + everything from
# ./mods). Mod id from <dir>/mod_id.txt if present, else the dir name.
{
    echo '<Mods>'
    for mod_dir in /app/mods/*/; do
        [ -d "$mod_dir" ] || continue
        if [ -f "${mod_dir}mod_id.txt" ]; then
            mod_id=$(tr -d '[:space:]' < "${mod_dir}mod_id.txt")
        else
            mod_id=$(basename "$mod_dir")
        fi
        echo "  <Mod enabled=\"1\" name=\"$mod_id\" settings_fold_open=\"0\" workshop_item_id=\"0\" />"
    done
    echo '</Mods>'
} > "$NOITA_DIR/save00/mod_config.xml"

# Harness mod runtime config. Lua syntax: unset NOITA_WORLD_SEED -> seed = nil
# (no override); set to an int -> SetWorldSeed(<int>).
cat > /app/mods/noita-docker-harness/runtime-config.lua <<EOF
return {
  seed = ${NOITA_WORLD_SEED:-nil},
}
EOF

log "launching: wine noita.exe $*"
cd /app

# stream noita's logger.txt to stdout to see it in `docker logs`
tail -F logger.txt 2>/dev/null &

exec wine noita.exe "$@"

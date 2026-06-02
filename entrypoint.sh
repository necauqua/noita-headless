#!/bin/sh
set -e

# Clear any stale signal from a prior run so the host can wait on its
# (re)appearance to detect this run's player-spawn.
rm -f /appdata/player_ready

log() { echo "[noita-docker] $*"; }

if [ ! -f /noita/noita.exe ]; then
    log "ERROR: /noita does not contain noita.exe. Mount the game folder:"
    log "  docker run -v \"\$PWD/noita:/noita:ro\" ... noita-headless"
    exit 1
fi

log "starting Xvfb on :99"
Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
XVFB_PID=$!
trap 'kill "$XVFB_PID" 2>/dev/null' EXIT

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
cp -rs /noita /app

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
#   last_started_game_version_hash matches the game's _version_hash.txt
#     -> skips the "Welcome to Noita Update" popup
#   mods_sandbox_enabled="0" + dismissed disclaimer flags
#     -> mods get unsandboxed Lua (needed for the harness mod's file signal)
cat > "$NOITA_DIR/save_shared/config.xml" <<EOF
<Config
  config_format_version="14"
  mods_disclaimer_accepted="1"
  mods_sandbox_enabled="0"
  mods_sandbox_warning_done="1"
  last_started_game_version_hash="$(cat /noita/_version_hash.txt)"
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

#!/bin/sh
set -e

# One long-lived Xvfb for the whole container lifetime
Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
XVFB_PID=$!
trap 'kill "$XVFB_PID" 2>/dev/null' EXIT

# Point %APPDATA%\..\LocalLow (where Noita stores its save data) at /appdata,
# so mounting -v ./appdata:/appdata persists saves independently of the prefix.
USER_DIR="$WINEPREFIX/drive_c/users/$(whoami)"
mkdir -p "$USER_DIR/AppData"
if [ ! -L "$USER_DIR/AppData/LocalLow" ]; then
    rm -rf "$USER_DIR/AppData/LocalLow"
    ln -s /appdata "$USER_DIR/AppData/LocalLow"
fi

# Populate /noita/mods (tmpfs, see compose.yaml) from two sources:
#   /opt/noita-docker-harness  baked into the image at build time
#   /user-mods                 the host's ./mods bind-mount (read-only)
# The harness is copied (entrypoint writes runtime_config.lua into it below).
# User mods are symlinked so edits on the host are picked up without rebuild.
# Wipe first: under podman the tmpfs is pre-populated with the bundled mods
# from the underlying /noita/mods bind (Docker hides them instead). Either
# way we want /noita/mods to contain only what we put here.
rm -rf /noita/mods/*
cp -r /opt/noita-docker-harness /noita/mods/
for src in /user-mods/*/; do
    [ -d "$src" ] || continue
    ln -sfn "$src" "/noita/mods/$(basename "$src")"
done

# Pre-seeding save state:

NOITA_DIR=/appdata/Nolla_Games_Noita
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

# Auto-enable every mod under /noita/mods (the harness + everything from
# ./mods). Mod id from <dir>/mod_id.txt if present, else the dir name.
{
    echo '<Mods>'
    for mod_dir in /noita/mods/*/; do
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

# Clear any stale signal from a prior run so the host can wait on its
# (re)appearance to detect this run's player-spawn.
rm -f /appdata/player_ready

# Harness mod runtime config. Lua syntax: unset NOITA_WORLD_SEED -> seed = nil
# (no override); set to an int -> SetWorldSeed(<int>).
cat > /noita/mods/noita-docker-harness/runtime_config.lua <<EOF
return {
  seed = ${NOITA_WORLD_SEED:-nil},
}
EOF

cd /noita
exec wine noita.exe "$@"

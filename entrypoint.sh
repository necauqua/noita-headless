#!/bin/sh
set -e

# One long-lived Xvfb for the whole container lifetime
Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
XVFB_PID=$!
trap 'kill "$XVFB_PID" 2>/dev/null' EXIT

# Initialize the wineprefix on first run.
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    wineboot -i
    wineserver -w
fi

# Point %APPDATA%\..\LocalLow (where Noita stores its save data) at /appdata,
# so mounting -v ./appdata:/appdata persists saves independently of the prefix.
USER_DIR="$WINEPREFIX/drive_c/users/$(whoami)"
mkdir -p "$USER_DIR/AppData"
if [ ! -L "$USER_DIR/AppData/LocalLow" ]; then
    rm -rf "$USER_DIR/AppData/LocalLow"
    ln -s /appdata "$USER_DIR/AppData/LocalLow"
fi

# Pre-seed steps. Each is gated by an env var (all default to 1):
#  NOITA_SKIP_INTRO          touch save00/persistent/flags/intro_has_played -
#                            skips the first-game-start cutscene
#  NOITA_SKIP_RELEASE_NOTES  write save_shared/config.xml with
#                            last_started_game_version_hash matching the game,
#                            skipping the "Welcome to Noita Update" popup
#  NOITA_AUTO_ENABLE_MODS    write save00/mod_config.xml enabling every dir
#                            under /noita/mods (mounted from ./mods)
NOITA_DIR=/appdata/Nolla_Games_Noita
mkdir -p "$NOITA_DIR/save00/persistent/flags" "$NOITA_DIR/save_shared"

if [ "${NOITA_SKIP_INTRO:-1}" = "1" ]; then
    touch "$NOITA_DIR/save00/persistent/flags/intro_has_played"
fi

if [ "${NOITA_SKIP_RELEASE_NOTES:-1}" = "1" ]; then
    VERSION_HASH=$(cat /noita/_version_hash.txt)
    cat > "$NOITA_DIR/save_shared/config.xml" <<EOF
<Config
  config_format_version="14"
  mods_disclaimer_accepted="1"
  mods_sandbox_enabled="0"
  mods_sandbox_warning_done="1"
  last_started_game_version_hash="$VERSION_HASH"
/>
EOF
fi

if [ "${NOITA_AUTO_ENABLE_MODS:-1}" = "1" ]; then
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
fi

cd /noita
exec wine noita.exe "$@"

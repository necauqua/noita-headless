# noita-docker

Run [Noita](https://noitagame.com/) headless in a container — Wine + Xvfb + Mesa
software OpenGL, no GPU, no audio device, no user interaction. Built for
automated tests that drive the game from outside.

## Layout

```
.
├── Dockerfile          # debian:bookworm-slim + wine32 + Xvfb + Mesa llvmpipe
├── compose.yaml        # one service `noita`, mounts `./noita`, `./appdata` and `./mods`
├── entrypoint.sh       # starts Xvfb, links AppData, pre-seeds saves, runs noita.exe
├── screenshot.sh       # xwd -> pnm -> png from the in-container Xvfb display
├── noita/              # the game folder (mounted read-only) -- bring your own
├── appdata/            # Noita's %APPDATA%/.../LocalLow (saves, screenshots)
└── mods/<id>/          # mods (mounted read-only on top of the game's mods dir)
```

`noita/` and `appdata/` are git-ignored; `mods/` is tracked (it contains the
example `test-mod`).

## Prerequisites

- Docker or Podman with the compose plugin
- A Noita install in `./noita/` (the folder containing `noita.exe`, `data/`,
  `_version_hash.txt`, etc.)

## Quick start

```sh
docker compose build
docker compose run --rm -d --name noita noita -gamemode 0
docker exec noita /screenshot.sh > shot.png
docker stop noita
```

Anything after the service name in `compose run` is forwarded to `noita.exe`
(via the entrypoint's `exec wine noita.exe "$@"`). `-gamemode 0` is equivalent
to clicking *New Game* from the menu; without args the container parks on the
main menu.

## How it works

### Display

Xvfb runs on `:99` for the lifetime of the container (started by the
entrypoint). Mesa's llvmpipe handles OpenGL in software via the i386
`libgl1-mesa-dri` package — no GPU needed. `LIBGL_ALWAYS_SOFTWARE=1` keeps it
deterministic.

### Wine

A 32-bit prefix (`WINEARCH=win32`) lives at `/wineprefix`, persisted in a
**named volume** (`wineprefix:`). `wineboot -i` runs during the image build so
the first `compose run` doesn't pay the ~30 s init cost — when an empty named
volume is mounted to a path that already has content in the image, the
runtime copies the image's content into the volume on first mount. Bind
mounts do not do this, so the prefix must be a named volume; see
<https://docs.docker.com/engine/storage/volumes/#populate-a-volume-using-a-container>.

`WINEDLLOVERRIDES` disables three DLLs: `mscoree`/`mshtml` (skip the .NET +
Gecko download prompt) and `winealsa.drv` (no audio device exists in the
container; not loading the ALSA bridge keeps libasound2 from spamming
`cannot find card '0'`).

### Save pre-seeding

`entrypoint.sh` writes a few files under `appdata/Nolla_Games_Noita/` before
launching the game. Each step is gated by an env var (all default to `1`):

| env var | when `1` | when `0` |
|---|---|---|
| `NOITA_SKIP_INTRO` | touch `save00/persistent/flags/intro_has_played` | first-game cutscene plays |
| `NOITA_SKIP_RELEASE_NOTES` | write `save_shared/config.xml` with `last_started_game_version_hash` matching `_version_hash.txt` + `mods_sandbox_enabled="0"` + disclaimer flags | "Welcome to Noita Update" popup appears, mods sandbox stays default |
| `NOITA_AUTO_ENABLE_MODS` | scan `/noita/mods/*/`, write `save00/mod_config.xml` enabling each | Noita's own state wins |

The `AppData/LocalLow` directory inside the wineprefix is a symlink to
`/appdata`, so saves persist on the host even though the prefix lives in a
docker-managed volume.

### Mods

`./mods/<id>/` is bind-mounted (read-only) at `/noita/mods/<id>`, replacing
the read-only mods that ship with the game. For each subdir, the entrypoint
takes the id from `mod_id.txt` if present, else the directory name, and
writes a corresponding `<Mod enabled="1" name="…" />` into
`save00/mod_config.xml`.

`mods/test-mod/` is included as a smoke test — its `init.lua` renders
"test mod loaded" at `(10, 10)` every world update.

### Input + screenshots

`xdotool` is installed so external tools can synthesize keyboard/mouse events
against `:99`:

```sh
docker exec noita xdotool key Return
docker exec noita xdotool mousemove 100 200 click 1
docker exec noita xdotool search --name Noita getwindowname
```

`screenshot.sh` dumps the current display through `xwd | xwdtopnm | pnmtopng`
and writes the result to its first arg (or stdout if none).

```sh
docker exec noita /screenshot.sh > shot.png
```

## Commands

```sh
# Build / rebuild the image
docker compose build

# Run, detached, with a -gamemode arg
docker compose run --rm -d --name noita noita -gamemode 0

# Run with a pre-seed step disabled
docker compose run --rm -d --name noita -e NOITA_SKIP_INTRO=0 noita -gamemode 0

# Screenshot
docker exec noita /screenshot.sh > shot.png

# Send input
docker exec noita xdotool key Return
docker exec noita xdotool mousemove 95 660 click 1

# Stop + clean
docker stop noita

# Wipe save state between runs
rm -rf appdata && mkdir appdata

# Wipe the wineprefix (forces a fresh wineboot on next start)
docker volume rm noita-docker_wineprefix
```

## AI Assistance

This project was built in a pair-programming session with Claude Opus 4.7
(Anthropic) driving the file edits, container builds, and verification runs
through the Claude Code CLI.

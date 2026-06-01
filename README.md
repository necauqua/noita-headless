# noita-docker

Run [Noita](https://noitagame.com/) headless in a container — Wine + Xvfb + Mesa
software OpenGL, no GPU, no audio device, no user interaction. Built for
automated tests that drive the game from outside.

## Layout

```
.
├── Dockerfile                # debian:bookworm-slim + wine32 + Xvfb + Mesa llvmpipe
├── compose.yaml              # one service `noita`, mounts `./noita`, `./appdata`, `./mods`
├── entrypoint.sh             # Xvfb, AppData link, mod merge, save pre-seed, run noita.exe
├── screenshot.sh             # xwd -> pnm -> png from the in-container Xvfb display
├── justfile                  # parameterized recipes for common operations
├── noita-docker-harness/     # mod baked into the image (see *Harness mod*)
├── noita/                    # the game folder (mounted read-only) -- bring your own
├── appdata/                  # Noita's %APPDATA%/.../LocalLow (saves, screenshots)
└── mods/<id>/                # user mods (host-side; merged into /noita/mods at start)
```

`noita/` and `appdata/` are gitignored; `mods/` ships the example `test-mod`.

## Prerequisites

- Docker or Podman with the compose plugin
- [`just`](https://github.com/casey/just) — recipes for common operations
- A Noita install in `./noita/` (the folder containing `noita.exe`, `data/`,
  `_version_hash.txt`, etc.)

## Quick start

```sh
just build
just start          # runs `noita -gamemode 0`, waits until the player has spawned
just screenshot     # writes ./shot.png
just stop
```

`just start` is `run` + `wait`. `run` does `docker compose run --rm -d`
forwarding the `args` variable to `noita.exe` (default `-gamemode 0` = *New
Game*; without args the container parks on the main menu). `wait` blocks
until the harness mod signals player-spawn (see below).

Override any variable on the CLI: `just seed=12345 start`,
`just args="-gamemode 0 -no_logo_splashes" start`, `just name=noita-test start`.
Run `just` for the full recipe menu.

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

Before launching the game, `entrypoint.sh` writes a handful of files under
`appdata/Nolla_Games_Noita/`, unconditionally:

- `save00/persistent/flags/intro_has_played` — skips the intro cutscene.
- `save_shared/config.xml` with `last_started_game_version_hash` matching the
  game's `_version_hash.txt` (skips the "Welcome to Noita Update" popup) and
  `mods_sandbox_enabled="0"` (lets the harness mod use unsandboxed Lua to write
  the player_ready signal) + the disclaimer-dismissed flags.
- `save00/mod_config.xml` enabling every directory under `/noita/mods/` —
  i.e. the harness plus everything the user put in `./mods/`. Mod id comes
  from `mod_id.txt` if present, else the directory name.

The `AppData/LocalLow` directory inside the wineprefix is a symlink to
`/appdata`, so saves persist on the host even though the prefix lives in a
docker-managed volume.

### Mods

`/noita/mods` is a **tmpfs** owned by the container. The entrypoint
populates it from two sources:

- `/opt/noita-docker-harness/` — baked into the image at build time. Copied in
  so the entrypoint can write `runtime_config.lua` into it (see *Harness mod*
  below).
- `/user-mods/` — the host's `./mods` bind-mounted read-only. Each subdir
  is symlinked into `/noita/mods/`, so edits on the host are picked up on
  the next container start without a rebuild.

For each resulting subdir, the entrypoint takes the id from `mod_id.txt` if
present, else the directory name, and writes a corresponding
`<Mod enabled="1" name="…" />` into `save00/mod_config.xml`.

`mods/test-mod/` is included as a smoke test — its `init.lua` renders
"test mod loaded" at `(10, 10)` every world update.

### Harness mod

`noita-docker-harness/` (top-level) is baked into the image and helps with a
few things:

- **Player-spawn signal.** `OnPlayerSpawned` writes `/appdata/player_ready`
  (via Wine's `Z:\` path). The file appears the instant the player entity
  exists — fastest reliable "in-game, ready" signal. The entrypoint deletes
  any stale file before launch, so its appearance is unambiguous per run. Use
  `just wait` (or `until [ -e appdata/player_ready ]; do sleep 0.2; done`)
  host-side.
- **Seed override.** `NOITA_WORLD_SEED=<seed>` being set calls
  `SetWorldSeed(<seed>)`.

Env vars are not visible to Noita's Lua directly; the entrypoint writes a
small `runtime_config.lua` next to `init.lua` at start, and the mod
`dofile_once`s it.

### Input + screenshots

`xdotool` is installed so external tools can synthesize keyboard/mouse events
against `:99`:

```sh
just xdotool key Escape
just xdotool mousemove 100 200 click 1
```

`screenshot.sh` dumps the current display through `xwd | xwdtopnm | pnmtopng`
and writes the result to its first arg (or stdout if none). `just screenshot
[path]` is the host-side wrapper.

## Commands

Running just `just` will list the recipes. Highlights:

| recipe | what it does |
|---|---|
| `just build` | `docker compose build` |
| `just run` | start the container detached (`args` and `seed` are honored) |
| `just wait [timeout]` | block until `appdata/player_ready` appears, fail after `timeout` (default 120 s) |
| `just start` | `run` then `wait` |
| `just screenshot [path]` | write the current frame to `path` (default `./shot.png`) |
| `just xdotool …` | run xdotool inside the container, args passed through |
| `just logs` | `docker logs -f` the container |
| `just stop` | stop the container |
| `just clean-saves` | `rm -rf appdata && mkdir appdata` |
| `just clean-prefix` | drop the wineprefix volume (next start re-pays wineboot) |
| `just nuke` | `stop` + `clean-saves` + `clean-prefix` |

Just variables can be overridden:

```sh
just args="-gamemode 0 -no_logo_splashes" run # explicit noita.exe args (matches the default)
just seed=12345 start                         # set the seed 12345
just name=noita-test start                    # parallel runs with distinct names
```

## AI Assistance

This project was built in a pair-programming session with Claude Opus 4.7
(Anthropic) driving the file edits, container builds, and verification runs
through the Claude Code CLI.

# noita-docker

Run [Noita](https://noitagame.com/) headless in a container — Wine + Xvfb + Mesa
software OpenGL, without a GPU. Can be used for automated tests or to run Lua
code in a real running Noita engine.

## Layout

```
.
├── Dockerfile                # debian:bookworm-slim + wine32 + Xvfb + Mesa llvmpipe
├── entrypoint.sh             # Xvfb, AppData link, /noita -> /app mirror, save pre-seed, run noita.exe
├── screenshot.sh             # xwd -> pnm -> png from the in-container Xvfb display
├── justfile                  # parameterized recipes for common operations
├── noita-docker-harness/     # mod baked into the image (see *Harness mod*)
├── noita/                    # the game folder (mounted read-only) -- bring your own
└── mods/<id>/                # user mods (host-side; merged into /app/mods at start)
```

`noita/` is gitignored; `mods/` ships the example `test-mod`.

## Prerequisites

- Docker or Podman
- A Noita install in `./noita/` (the folder containing `noita.exe`, `data/`,
  `_version_hash.txt`, etc.)
- Optional: [`just`](https://github.com/casey/just) for the recipes below.
  Without it everything still works via plain `docker build` / `docker run`.

## Quick start (with just)

```sh
just build
just start      # runs the container and waits until the player has spawned
just screenshot # writes ./shot.png
just clean      # stops the container and removes the save (use `just stop` to keep the save)
```

Override variables on the CLI: `just seed=12345 start`,
`just args="-gamemode 2 -no_logo_splashes" start`, `just name=second start`.
Run `just` for the full recipe menu.

`name` is used as a container name suffix as well as the key for the
`noita-appdata-<name>` named volume that persists the save across runs.
Distinct names → independent containers and independent saves.

## Quick start (without just)

```sh
docker build -t noita-headless .

# Minimum: just bind your Noita install. Saves are ephemeral (--rm wipes them).
docker run --rm -d --name noita \
    -v "$PWD/noita:/noita:ro" \
    noita-headless -gamemode -no_logo_splashes

# Add a host folder of mods (optional):
docker run --rm -d --name noita \
    -v "$PWD/noita:/noita:ro" \
    -v "$PWD/mods:/mods:ro" \
    noita-headless

# Add a named volume so saves persist across `--rm` cycles (optional):
docker run --rm -d --name noita \
    -v "$PWD/noita:/noita:ro" \
    -v noita-appdata-default:/appdata \
    noita-headless

docker exec noita /screenshot.sh > shot.png
docker rm -f --time 0 noita
```

Only `/noita` is required. `/mods` and `/appdata` are both optional —
without `/appdata` the save lives in the container's writable layer and goes
away with `--rm`.

## How it works

### Display

Xvfb runs on `:99` for the lifetime of the container (started by the
entrypoint). Mesa's llvmpipe handles OpenGL in software via the i386
`libgl1-mesa-dri` package — no GPU needed. `LIBGL_ALWAYS_SOFTWARE=1` keeps it
deterministic.

### Wine

A 32-bit prefix (`WINEARCH=win32`) lives at `/wineprefix` and is baked into
the image (`wineboot -i` runs during build) to avoid the per-start `wineboot`
cost.

`WINEDLLOVERRIDES` disables three DLLs: `mscoree`/`mshtml` (skip the .NET +
Gecko download prompt) and `winealsa.drv` (no audio device exists in the
container; not loading the ALSA bridge keeps libasound2 from spamming
`cannot find card '0'`).

### Save pre-seeding

Before launching the game, `entrypoint.sh` writes a handful of files into
`/appdata/Nolla_Games_Noita/`:

- `save00/persistent/flags/intro_has_played` — skips the intro cutscene.
- `save_shared/config.xml` with `last_started_game_version_hash` matching the
  game's `_version_hash.txt` (skips the "Welcome to Noita Update" popup) and
  `mods_sandbox_enabled="0"` (lets the harness mod use unsandboxed Lua to write
  the `player_ready` signal) + the disclaimer-dismissed flags.
- `save00/mod_config.xml` enabling every directory under `/noita/mods/` —
  i.e. the harness plus everything the user put in `./mods/`. Mod id comes
  from `mod_id.txt` if present, else the directory name.

The `AppData/LocalLow` directory inside the wineprefix is a symlink to
`/appdata`. With no `-v` mount at `/appdata` the save lives in the writable
container layer (ephemeral under `--rm`). With `-v <vol>:/appdata` it
persists across container lifecycles.

### Mods (and `/noita` → `/app` mirror)

The `/noita` bind is read-only, so the entrypoint can't write a mods folder
into it. Instead it builds a writable mirror at `/app` with `cp -rs /noita
/app`: every file in `/app` is a symbolic link to the corresponding
`/noita` file (wine still reads them directly from the host bind), but
directories are real, so `/app/mods` can be wiped and repopulated freely.
The mirror lives in the container's writable layer — under `--rm` it goes
away with the container. Works under docker and podman (rootless), no
tmpfs/mount privileges needed.

After mirroring, the entrypoint wipes `/app/mods` and fills it from:

- `/opt/noita-docker-harness/` — baked into the image at build time. Copied
  in so the entrypoint can write `runtime-config.lua` into it (see *Harness
  mod* below).
- `/mods/` — the host's `./mods` (or whatever you bind to `/mods`)
  read-only. Each subdir is symlinked into `/app/mods/`, so edits on the
  host are picked up on the next container start without a rebuild.

For each resulting subdir, the entrypoint takes the id from `mod_id.txt` if
present, else the directory name, and writes a corresponding
`<Mod enabled="1" name="…" />` into `save00/mod_config.xml`.

`mods/test-mod/` is included as a smoke test — its `init.lua` renders
"test mod loaded" in the corner of the screen.

### Harness mod

`noita-docker-harness/` (top-level) is baked into the image and helps with a
few things:

- **Player-spawn signal.** `OnPlayerSpawned` writes `/appdata/player_ready`
  (via Wine's `Z:\` path). The file appears the instant the player entity
  exists — fastest reliable "in-game, ready" signal. The entrypoint deletes
  any stale file before launch, so its appearance is unambiguous per run.
  Use `just wait`, which polls `docker exec {{name}} test -e /appdata/player_ready`
  (since the appdata volume isn't visible on the host filesystem).
- **Seed override.** `NOITA_WORLD_SEED=<seed>` being set calls
  `SetWorldSeed(<seed>)`.

Env vars are not visible to Noita's Lua directly; the entrypoint writes a
small `runtime-config.lua` next to `init.lua` at start, and the mod
`dofile_once`s it.

### Input + screenshots

`xdotool` is installed so external tools can synthesize keyboard/mouse events
against `:99`:

```sh
just send key Escape
just send mousemove 100 200 click 1
```

`screenshot.sh` dumps the current display through `xwd | xwdtopnm | pnmtopng`
and writes the result to its first arg (or stdout if none). `just screenshot
[path]` is the host-side wrapper.

## Commands

`just` lists the menu. Highlights:

| recipe | what it does |
|---|---|
| `just build` | `docker build -t noita-headless .` |
| `just start` | run the container detached (`args`, `seed`, `name` honored) |
| `just wait [timeout]` | poll `/appdata/player_ready` via `docker exec`, fail after `timeout` (default 120 s) |
| `just screenshot [path]` | write the current frame to `path` (default `./shot.png`) |
| `just send …` | run xdotool inside the container, args passed through |
| `just list` | running noita containers |
| `just logs` | `docker logs -f` the container |
| `just stop` | kill + remove the container (saves stay in the volume) |
| `just clean` | `stop` then drop the `noita-appdata-{{name}}` volume |

## AI Assistance

This project was built in a pair-programming session with Claude Opus 4.7
(Anthropic) driving the file edits, container builds, and verification runs
through the Claude Code CLI.

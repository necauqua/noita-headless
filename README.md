# noita-headless

Run [Noita](https://noitagame.com/) headless in a container — Wine + Xvfb + Mesa
software OpenGL, without a GPU. Can be used for automated tests or to run Lua
code in a real running Noita engine.

## Layout

```
.
├── Dockerfile                # debian:bookworm-slim + wine32 + Xvfb + Mesa llvmpipe
├── Dockerfile.bake           # extends `noita-headless` with the noita install baked in (used by `just bake`)
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
just start wait # runs the container and waits until the world is loaded
sleep 4         # a little bit of extra wait for the initial fade in
just screenshot # captures the screen to shot.png
open shot.png   # view it
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

# Minimum: just bind your Noita install, the save is not preserved.
docker run --rm -d --name noita \
    -v "$PWD/noita:/noita:ro" \
    noita-headless -gamemode -no_logo_splashes

# Bind a folder of mods to be installed into the game:
docker run --rm -d --name noita \
    -v "$PWD/noita:/noita:ro" \
    -v "$PWD/mods:/mods:ro" \
    noita-headless

# Add a bind mount volume so saves persist across `--rm` cycles (optional):
docker run --rm -d --name noita \
    -v "$PWD/noita:/noita:ro" \
    -v noita-appdata-default:/appdata \
    noita-headless

docker exec noita /screenshot.sh > shot.png

# This will most likely not properly write the save if you bind-mount
# appdata as described above - in my experience the best result was actually
# sending alt+f4 to it via xdotool, see the `just stop` recipe.
docker stop noita 
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

A 32-bit prefix (`WINEARCH=win32`) is baked into the image at `/wineprefix`
(`wineboot -i` runs during build). Nothing is mounted there at runtime —
each `--rm` container gets a fresh copy via its writable layer. The
container's PID 1 is `tini`, which forwards `SIGTERM` to wine so `docker
stop` actually reaches noita.

### Audio

Wine and FMOD spam the log with init-failure noise when they can't find an
audio device, so `/etc/asound.conf` configures a null sink and audio "works",
making the error logs go away.

### Logging

The harness mod ships `magic-numbers.xml` (credit to
[Enable Logger](https://steamcommunity.com/sharedfiles/filedetails/?id=2124936579))
that tunes Noita logger to be slightly less useless.

The entrypoint runs `tail -F /app/logger.txt` in the background, so Noita's
runtime log shows up in `docker logs`.

### Save pre-seeding

Before launching the game, `entrypoint.sh` writes a handful of files into
`/appdata/Nolla_Games_Noita/`:

- `save00/persistent/flags/intro_has_played` — skips the intro cutscene.
- `save_shared/config.xml` with `last_started_game_version_hash` matching the
  game's `_version_hash.txt` (skips the "Welcome to Noita Update" popup) and
  `mods_sandbox_enabled="0"` (lets the harness mod use unsandboxed Lua to write
  the `player_ready` signal) + the disclaimer-dismissed flags.
- `save00/mod_config.xml` enabling every directory under `/app/mods/` —
  i.e. the harness plus everything the user put in `./mods/`. Mod id comes
  from `mod_id.txt` if present, else the directory name.

The `AppData/LocalLow` directory inside the wineprefix is a symlink to
`/appdata`. With no `-v` mount at `/appdata` the save lives in the writable
container layer (ephemeral under `--rm`). With `-v <vol>:/appdata` it
persists across container lifecycles.

### Mods (and `/noita` → `/app` mirror)

The `/noita` bind is read-only, so we cant edit the mods folder and Noita can't
write logs at the very least.

So we build a symlink tree at `/app` inside of the container instead.

The read-only bind ensures the container does not modify the Noita instance
that was given to it, and you can point it directly at your Steam installation
without fearing any issues.

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

- **Ready signal.** `OnWorldPreUpdate` writes `/app/player_ready` the
  first frame the world is up, then sets itself to `nil` (fire-once). We
  use `OnWorldPreUpdate` rather than `OnPlayerSpawned` because the latter
  doesn't fire when the player entity is loaded from a save. The entrypoint
  deletes any stale file before launch, so its appearance is unambiguous
  per run. Use `just wait`, which polls
  `docker exec {{container}} test -e /app/player_ready` (the appdata
  volume isn't visible on the host filesystem).
- **Seed override.** `NOITA_WORLD_SEED=<seed>` being set calls
  `SetWorldSeed(<seed>)`.
- **Enables Noita's logger.** See *Logging* above.

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

## Baking a standalone image

Note that this is a questionable thing to do and you *definitely* shouldn't
redistribute such an image.

`just bake` builds a self-contained image (default tag: `noita-headless-baked`)
that doesn't need the `-v <path>:/noita` bind at run time. It rsyncs `./noita`
(or `src=<path>`) into a temp build context, drops `tools_modding/`, `mods/`,
and `**.bank` audio (~1.2 GB of dead weight in a no-audio container), then
layers it on top of `noita-headless`.

```sh
just bake                          # → localhost/noita-headless-baked
just bake src=/path/to/noita
just bake tag=noita-headless-myrun
```

`Master Bank.bank` + `Master Bank.strings.bank` (~2.4 MB) are kept even
though `*.bank` is otherwise excluded — without them noita's audio.cpp
hammers `Code: 74 — could not be found` thousands of lines per session.
With the metadata banks present, FMOD's event-lookup table is populated and
the only error noise left is ~15 startup-only `File not found` notices for
the missing sub-banks.

Running the baked image needs no `/noita` mount:

```sh
docker run --rm -d --name noita \
    -v noita-appdata-default:/appdata \
    noita-headless-baked
```

The justfile's `start` recipe still bind-mounts `./noita`, so it's tied to
the `noita-headless` image; run the baked one with plain `docker run` as
above.

## Commands

`just` lists the menu. Highlights:

| recipe | what it does |
|---|---|
| `just build` | `docker build -t noita-headless .` |
| `just bake [src=…] [tag=…]` | build a standalone image with noita baked in (no `-v …:/noita` needed) |
| `just start` | run the container detached (`args`, `seed`, `name` honored) |
| `just wait [timeout]` | poll `/app/player_ready` via `docker exec`, fail after `timeout` (default 120 s) |
| `just screenshot [path]` | write the current frame to `path` (default `./shot.png`) |
| `just send …` | run xdotool inside the container, args passed through |
| `just list` | running noita containers |
| `just logs` | `docker logs -f` the container |
| `just stop` | graceful shutdown: alt+F4 to noita, wait for `noita.exe` to exit, `docker stop` fallback — gives noita a chance to save |
| `just clean` | `stop` then drop the `noita-appdata-{{name}}` volume |

## AI Assistance

This project was built in a pair-programming session with Claude Opus 4.7
(Anthropic) driving the file edits, container builds, and verification runs
through the Claude Code CLI.

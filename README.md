# noita-headless

Run [Noita](https://noitagame.com/) headless in a container — Wine + Xvfb + Mesa
software OpenGL, without a GPU. Can be used for automated tests or to run Lua
code in a real running Noita engine.

## Layout

```
.
├── Dockerfile                # debian:trixie-slim + GE-Proton's Wine + Xvfb + Mesa llvmpipe
├── .dockerignore             # keeps the build context to the few files the image needs
├── Dockerfile.bake           # extends `noita-headless` with the noita install baked in (used by `just bake`)
├── entrypoint.sh             # Xvfb, AppData link, /noita -> /app mirror, save pre-seed, run noita.exe
├── screenshot.sh             # xwd -> pnm -> png from the in-container Xvfb display
├── wait-ready.sh             # in-container: block until the world is loaded
├── shutdown.sh               # in-container: alt+F4 to noita, wait for it to exit
├── scripts/                  # host-side helpers, usable without just
│   ├── locate-noita.sh       #   find Noita in the Steam library
│   ├── noita-version.sh      #   build date scraped out of noita.exe
│   └── bake.sh               #   build a standalone image with noita inside
├── justfile                  # thin wrappers around the above, for common operations
├── noita-docker-harness/     # mod baked into the image (see *Harness mod*)
└── mods/<id>/                # user mods (host-side; merged into /app/mods at start)
```

## Prerequisites

- Docker or Podman
- A Noita install in a known location (Steam or otherwise)
- Optional: [`just`](https://github.com/casey/just) for the recipes below.
  Without it everything still works via plain `docker build` / `docker run`
  plus the scripts in `scripts/` (see *Quick start (without just)*).

## Quick start (with just)

```sh
just build # needed once

just start      # start the container
just wait       # wait until the world is loaded
sleep 4         # a little bit of extra wait for the initial fade in
just screenshot # capture the screen to shot.png
open shot.png   # and view it
just reset      # stop the container and remove the appdata volume (use `just stop` to keep the save)
```

Override variables on the CLI: `just seed=12345 start`,
`just args="-gamemode 2 -no_logo_splashes" start`, `just name=second start`,
`just vnc=true start` (see *VNC* below), `just docker=podman start`,
`just resolution=1920x1080x24 start`, `just image=noita-headless:2024-01-30
start` (see *Baking* below). Run `just` for the full recipe menu.

`just test` does the whole build → boot → wait → screenshot cycle in one go
under a dedicated `name`, as a smoke test.

`name` is used as a container name suffix as well as the key for the
`noita-appdata-<name>` named volume that persists the save across runs.
Distinct names → independent containers and independent saves.

## Quick start (without just)

```sh
docker build -t noita-headless .

# Minimum: just bind your Noita install, the save is not preserved.
docker run --rm -d --name noita \
    -v "$NOITA_INSTALL:/noita:ro" \
    noita-headless -gamemode 0 -no_logo_splashes

# Bind a folder of mods to be installed into the game:
docker run --rm -d --name noita \
    -v "$NOITA_INSTALL:/noita:ro" \
    -v "$PWD/mods:/mods:ro" \
    noita-headless

# Add a bind mount volume so saves persist across `--rm` cycles (optional):
docker run --rm -d --name noita \
    -v "$NOITA_INSTALL:/noita:ro" \
    -v noita-appdata-default:/appdata \
    noita-headless

# Block until the harness mod signals that the world is up (default 120s)
docker exec noita /wait-ready.sh 120

docker exec noita /screenshot.sh > shot.png

# Synthesize input
docker exec noita xdotool key Escape

# A plain `docker stop` will most likely not write the save if you bind-mount
# appdata as described above, so alt+F4 the game and wait for it to exit first.
docker exec noita /shutdown.sh 10
docker stop noita
```

Everything the recipes do is available this way: they are thin wrappers around
`/wait-ready.sh`, `/shutdown.sh` and `/screenshot.sh` inside the container, and
`scripts/*.sh` on the host (`locate-noita.sh`, `noita-version.sh`, `bake.sh`).
Downstream users of the image never need `just`.

Only the `/noita` bind is required. `/mods` and `/appdata` are both optional —
without `/appdata` the save lives in the container's writable layer and goes
away with `--rm`.

## How it works

### Display

Xvfb runs on `:99` for the lifetime of the container (started by the
entrypoint). Mesa's llvmpipe handles OpenGL in software via the
`libgl1-mesa-dri` package — no GPU needed. `LIBGL_ALWAYS_SOFTWARE=1` keeps it
deterministic.

Wine creates OpenGL contexts in `explorer.exe` when it starts, and with the
Mesa shader cache enabled each of them opens the cache files again. That adds
about 1.7s to every start, more than the cache saves, so the image sets
`MESA_SHADER_CACHE_DISABLE=true`.

The virtual screen is `1280x720x24`; `NOITA_RESOLUTION` (`just
resolution=…`) overrides the Xvfb geometry. That is the size of the display,
not of the game window — Noita picks that from its own config.

### Wine

The game runs on the Wine of a pinned
[GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) release, set
by the `GE_PROTON` build argument of the `Dockerfile` (`docker build
--build-arg GE_PROTON=…`). This is also the kind of Wine that runs the game on
Steam. The build downloads the release, checks its SHA-512 sum, and keeps only
what plain `wine` uses: the Wine binaries and libraries, vkd3d, the NLS files
and Wine's own fonts. DXVK, vkd3d-proton, Gecko, Mono, the media and speech
libraries and the other parts that only the `proton` script uses are removed.
Proton 11 needs glibc 2.38 or later, so the base image is Debian trixie.

The image does not run the `proton` script, only `wine` from the release, so
it sets the environment that the script would set and that the game needs:
`WINEDLLPATH`, and `WINENTSYNC=1`, `WINEFSYNC=1` and `WINEESYNC=1`. Wine uses
ntsync when `/dev/ntsync` is passed into the container (`--device
/dev/ntsync`, with the `ntsync` kernel module loaded on the host), else fsync,
else esync. On a Ryzen 5950X all of them, and plain wineserver
synchronisation, give the same time to `world_ready`.

A 64-bit prefix, which is Proton's default and runs the 32-bit game, is baked
into the image at `/wineprefix` (`wine wineboot -i` runs during build; Proton
has no `wineboot` script). Proton's Wine always names the Windows user
`steamuser`. Nothing is mounted there at runtime — each `--rm` container gets
a fresh copy via its writable layer. The container's PID 1 is `tini`, which
forwards `SIGTERM` to wine so `docker stop` actually reaches noita.

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
  the `world_ready` signal) + the disclaimer-dismissed flags.
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

So we build a symlink tree at `/app` inside of the container instead. Files
Noita rewrites inside its own install directory (`logger.txt`) are deleted
from the tree afterwards — otherwise they'd stay symlinks pointing into the
read-only bind and the game's writes would fail with `EROFS`.

`_version_hash.txt` gets replaced with a real file containing the constant
`static`, and `config.xml` is pre-seeded with the same value, so the update
popup can never show up regardless of which build is mounted.

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

- **Ready signal.** `OnWorldPreUpdate` writes `/app/world_ready` the
  first frame the world is up, then sets itself to `nil` (fire-once). We
  use `OnWorldPreUpdate` rather than `OnPlayerSpawned` because the latter
  doesn't fire when the player entity is loaded from a save. The signal is
  called `world_ready` and not `player_ready` because the world starts
  updating before the player entity exists. The entrypoint
  deletes any stale file before launch, so its appearance is unambiguous
  per run. It lives in the container's `/app`, not in the appdata volume, so
  it is not visible on the host filesystem — poll it with
  `docker exec <container> /wait-ready.sh [timeout]`, which `just wait` wraps.
- **Seed override.** `NOITA_WORLD_SEED=<seed>` being set calls
  `SetWorldSeed(<seed>)`. The value is templated straight into Lua, so the
  entrypoint rejects anything that is not an integer in `1..2147483647`
  (the range of valid Noita seeds).
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

### VNC

Setting `NOITA_VNC` (any non-empty value) makes the entrypoint start `x11vnc`
attached to `:99` on port 5900. `just vnc=true start` does that and adds
`-p localhost:5900:5900`, so any VNC client (TigerVNC, Remmina, KRDC, …)
pointed at `localhost:5900` shows the live display and forwards
mouse/keyboard.

No password is set — for a remote host, don't publish 5900 directly; SSH-tunnel
it instead:

```sh
ssh -L 5900:localhost:5900 user@remote
```

then connect the VNC client to `localhost:5900` on your local machine.

## Baking a standalone image

Note that this is a questionable thing to do and you *definitely* shouldn't
redistribute such an image.

`scripts/bake.sh` (wrapped by `just bake`) builds a self-contained image that
doesn't need the `-v <path>:/noita` bind at run time. The default tag is
`noita-headless:<build-date>`, where the date is scraped out of the
`Noita - Build … -` string inside `noita.exe`, and is printed at the end of
the build. It rsyncs your Noita
installation into a temp build context, dropping `tools_modding/`, `mods/`,
and `**.bank` audio (~1.2 GB of dead weight in a no-audio container), then
layers it on top of `noita-headless`.

```sh
just bake                          # → noita-headless:2024-01-30
just bake path=/path/to/noita
just bake tag=custom-image-tag

# same thing without just (the base image has to be built first):
docker build -t noita-headless .
scripts/bake.sh                    # → noita-headless:2024-01-30
scripts/bake.sh custom-tag /path/to/noita
```

`scripts/bake.sh` honours `DOCKER=podman` and `BASE_IMAGE=<image>`.

`Master Bank.bank` + `Master Bank.strings.bank` (~2.4 MB) are kept even
though `*.bank` is otherwise excluded — without them noita's audio.cpp
hammers `Code: 74 — could not be found` thousands of lines per session.
With the metadata banks present, FMOD's event-lookup table is populated and
the only error noise left is ~15 startup-only `File not found` notices for
the missing sub-banks.

Running the baked image does not need the `/noita` mount (the whole point):

```sh
docker run --rm -d --name noita noita-headless:2024-01-30
```

The recipes drive it too — point `image` at the baked tag and `start` skips
the `/noita` bind (and with it the Steam library lookup) automatically:

```sh
just image=noita-headless:2024-01-30 start
just image=noita-headless:2024-01-30 test
```

An explicit `path=` still wins, if you want to run some *other* install
against a baked image.

## Commands

`just` lists the menu. Highlights:

| recipe | what it does |
|---|---|
| `just build` | `docker build -t noita-headless .` |
| `just bake [tag=…]` | `scripts/bake.sh` — standalone image with noita baked in (run it via `just image=… start`) |
| `just locate-noita` | `scripts/locate-noita.sh` — print the Steam install path |
| `just version [path=…]` | `scripts/noita-version.sh` — print the build date of an install |
| `just start` | run the container, detached |
| `just wait [timeout]` | `docker exec <c> /wait-ready.sh` — block until the world is loaded, fail after `timeout` (default 120s) |
| `just screenshot [path]` | write the current frame to `path` (default `./shot.png`) |
| `just send …` | run xdotool inside the container, args passed through |
| `just list` | list running noita containers (anything named `noita-*`) |
| `just test [out]` | smoke test: build, boot, wait, screenshot, tear down |
| `just logs` | `docker logs -f` the container |
| `just stop` | `docker exec <c> /shutdown.sh` (alt+F4, wait for `noita.exe` to exit) + `docker stop` fallback — gives noita a chance to save |
| `just reset` | `stop` then drop the `noita-appdata-{{name}}` volume |


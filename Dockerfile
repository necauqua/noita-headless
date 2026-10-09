# GE-Proton release whose Wine runs the game. Proton's Wine is much newer than
# a distribution's Wine and is the Wine that the game gets on Steam.
ARG GE_PROTON=GE-Proton11-7

FROM debian:trixie-slim AS proton
ARG GE_PROTON

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Download and verify the release, and keep only what plain `wine` uses: the
# Wine binaries and libraries, vkd3d, the NLS files and Wine's own fonts.
# The rest (DXVK, vkd3d-proton, NVIDIA libraries, Gecko, Mono, media and
# speech libraries, the prefix template) is used only by the `proton` script
# or by games that Noita is not.
RUN set -e \
 && name="$GE_PROTON-x86_64" \
 && url="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$GE_PROTON" \
 && cd /tmp \
 && curl -fsSLO "$url/$name.tar.gz" \
 && curl -fsSLO "$url/$name.sha512sum" \
 && sha512sum -c "$name.sha512sum" \
 && mkdir /opt/proton \
 && tar xzf "$name.tar.gz" -C /opt/proton --strip-components=2 "$name/files" \
 && rm "$name.tar.gz" "$name.sha512sum" \
 && cd /opt/proton \
 && find lib -mindepth 1 -maxdepth 1 ! -name wine ! -name vkd3d -exec rm -rf {} + \
 && find lib/wine -mindepth 1 -maxdepth 1 ! -name '*-unix' ! -name '*-windows' -exec rm -rf {} + \
 && find share -mindepth 1 -maxdepth 1 ! -name wine -exec rm -rf {} + \
 && rm -rf share/wine/gecko share/wine/mono

# Proton 11 is built against glibc 2.38 or later, so the base must be trixie or
# newer.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/opt/proton/bin:$PATH \
    WINEDLLPATH=/opt/proton/lib/vkd3d:/opt/proton/lib/wine \
    WINEPREFIX=/wineprefix \
    WINEDEBUG=-all \
    LIBGL_ALWAYS_SOFTWARE=1 \
    DISPLAY=:99

# The same synchronisation settings as the `proton` script uses. Wine takes
# ntsync when /dev/ntsync is passed into the container (`--device
# /dev/ntsync`), else fsync, else esync.
ENV WINENTSYNC=1 WINEFSYNC=1 WINEESYNC=1

# Wine creates OpenGL contexts in explorer.exe when it starts. With the Mesa
# shader cache enabled, each of these opens the cache files again, which adds
# about 1.7s to every start, more than the cache saves.
ENV MESA_SHADER_CACHE_DISABLE=true

# The game is 32-bit and the Wine services are 64-bit, so the libraries that
# Wine loads are installed for both architectures.
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && libs="libx11-6 libxext6 libxrender1 libxrandr2 libxi6 libxcursor1 \
          libxinerama1 libxcomposite1 libxfixes3 libxxf86vm1 \
          libfreetype6 libfontconfig1 libgnutls30t64 libasound2t64 \
          libgl1 libgl1-mesa-dri" \
 && apt-get install -y --no-install-recommends \
        $libs $(for lib in $libs; do echo "$lib:i386"; done) \
        xvfb x11-apps xdotool x11vnc netpbm \
        tini \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
           /usr/share/doc /usr/share/man /usr/share/locale /usr/share/info \
 && mkdir -p /noita /wineprefix /appdata

# Proton's Wine reads /etc/machine-id at start and complains when it is
# missing. A slim image has none, so give it a random one.
RUN tr -d - < /proc/sys/kernel/random/uuid > /etc/machine-id

COPY --from=proton /opt/proton /opt/proton

# Bake the initial wineprefix into the image to save on startup time and a
# little bit of disk space via overlayfs. Proton has no `wineboot` script, so
# it runs through `wine`. Gecko and Mono are not in the image, so their
# installers are disabled.
RUN Xvfb :99 -screen 0 1280x720x24 -nolisten tcp & XVFB_PID=$! \
 && WINEDLLOVERRIDES="mscoree,mshtml=" wine wineboot -i \
 && wineserver -w \
 && kill $XVFB_PID \
 && rm -rf /tmp/.X* /tmp/wine-*

# Configure ALSA with a null device so there is "an audio device" and we don't
# get giga spammed by ALSA/FMOD errors about not having sound in the container
RUN printf 'pcm.!default { type null }\nctl.!default { type null }\n' > /etc/asound.conf

# Harness mod baked into the image. The entrypoint copies it (alongside the
# user's mods from /mods) into /app/mods at container start.
COPY noita-docker-harness/ /opt/noita-docker-harness/

COPY entrypoint.sh screenshot.sh wait-ready.sh shutdown.sh /
RUN chmod +x /entrypoint.sh /screenshot.sh /wait-ready.sh /shutdown.sh

# tini makes SIGTERM sent via `docker stop` to actually work
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]

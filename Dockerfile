FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    WINEPREFIX=/wineprefix \
    WINEARCH=win32 \
    WINEDEBUG=-all \
    LIBGL_ALWAYS_SOFTWARE=1 \
    DISPLAY=:99

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        wine wine32 \
        xvfb x11-apps xdotool netpbm \
        libgl1:i386 libgl1-mesa-dri:i386 \
        tini \
 && rm -rf /var/lib/apt/lists/* \
           /usr/share/doc /usr/share/man /usr/share/locale /usr/share/info \
 && mkdir -p /noita /wineprefix /appdata

# Bake the initial wineprefix into the image to save on startup time and a
# little bit of disk space via overlayfs.
RUN Xvfb :99 -screen 0 1280x720x24 -nolisten tcp & XVFB_PID=$! \
 && wineboot -i \
 && wineserver -w \
 && kill $XVFB_PID \
 && rm -rf /tmp/.X* /tmp/wine-*

# Configure ALSA with a null device so there is "an audio device" and we don't
# get giga spammed by ALSA/FMOD errors about not having sound in the container
RUN printf 'pcm.!default { type null }\nctl.!default { type null }\n' > /etc/asound.conf

# Harness mod baked into the image. The entrypoint copies it (alongside the
# user's mods from /mods) into /app/mods at container start.
COPY noita-docker-harness/ /opt/noita-docker-harness/

COPY entrypoint.sh screenshot.sh /
RUN chmod +x /entrypoint.sh /screenshot.sh

# tini makes SIGTERM sent via `docker stop` to actually work
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]

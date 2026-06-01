FROM debian:bookworm-slim

# WINEDLLOVERRIDES:
#   mscoree, mshtml skip the .NET + Gecko download prompt on prefix init
#   winealsa.drv    no audio device in the container; not loading
#                   Wine's ALSA bridge keeps libasound2 from
#                   spamming "cannot find card '0'" on startup
ENV DEBIAN_FRONTEND=noninteractive \
    WINEPREFIX=/wineprefix \
    WINEARCH=win32 \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree,mshtml,winealsa.drv=" \
    LIBGL_ALWAYS_SOFTWARE=1 \
    DISPLAY=:99

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        wine wine32 \
        xvfb x11-apps xdotool netpbm \
        libgl1:i386 libgl1-mesa-dri:i386 \
 && rm -rf /var/lib/apt/lists/* \
           /usr/share/doc /usr/share/man /usr/share/locale /usr/share/info \
 && mkdir -p /noita /wineprefix /appdata

# Bake the initial wineprefix into the image so the first `compose run` is
# fast. When an empty *named* volume is mounted to a path that already has
# content in the image, the runtime copies the image's content into the
# volume on first mount (existing/non-empty volume -> volume wins, image
# content is masked). Note this is named-volume-only behavior; a bind mount
# would mask the baked files even when the host dir is empty.
# https://docs.docker.com/engine/storage/volumes/#populate-a-volume-using-a-container
RUN Xvfb :99 -screen 0 1280x720x24 -nolisten tcp & XVFB_PID=$! \
 && wineboot -i \
 && wineserver -w \
 && kill $XVFB_PID \
 && rm -rf /tmp/.X* /tmp/wine-*

COPY entrypoint.sh screenshot.sh /
RUN chmod +x /entrypoint.sh /screenshot.sh

# Harness mod baked into the image. At container start the entrypoint copies
# it (and symlinks user mods from ./mods) into the /noita/mods tmpfs.
COPY noita-docker-harness/ /opt/noita-docker-harness/

WORKDIR /noita
ENTRYPOINT ["/entrypoint.sh"]

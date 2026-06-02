#!/bin/sh
# Dump the current Xvfb display to a PNG on stdout (or to $1 if given).
# Usage from host:  docker exec noita-default /screenshot.sh > shot.png
#                   docker exec noita-default /screenshot.sh /appdata/shot.png
DISPLAY=:99 xwd -root -silent | xwdtopnm 2>/dev/null | pnmtopng > "${1:-/dev/stdout}"

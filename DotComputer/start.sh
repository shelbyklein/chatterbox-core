#!/bin/sh
# A virtual screen, a window manager, a VNC server on it, and noVNC in front of that for
# Chatterbox's live view. Then the browser tool server, headed on that screen so you can watch.
Xvfb :99 -screen 0 1440x900x24 -nolisten tcp &
sleep 1
fluxbox >/dev/null 2>&1 &
x11vnc -display :99 -forever -shared -nopw -rfbport 5900 -localhost -quiet >/dev/null 2>&1 &
websockify --web /usr/share/novnc 6080 localhost:5900 >/dev/null 2>&1 &
exec playwright-mcp --port 8931 --host 0.0.0.0 --allowed-hosts '*' \
  --browser chromium --no-sandbox --user-data-dir /home/dot/profile --viewport-size 1440,900 \
  --output-dir /home/dot/Downloads

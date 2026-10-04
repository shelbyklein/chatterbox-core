# Dot's computer: a small Linux desktop with Chromium. Dot browses it through Playwright's
# MCP server (port 8931); you watch, and can take over, through noVNC (port 6080). Chatterbox
# builds and runs this with Docker and publishes both ports on 127.0.0.1 only.
FROM node:22-bookworm-slim

# English pages: without a language, Chromium guessed one.
ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:99 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11vnc fluxbox novnc websockify \
      fonts-noto fonts-noto-color-emoji ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*

# The tool server, and the Chromium its Playwright version expects.
RUN npm install -g @playwright/mcp@0.0.83 \
    && cd /usr/local/lib/node_modules/@playwright/mcp \
    && npx playwright install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/* /root/.npm

# Downloads are the one folder shared with the Mac (Chatterbox mounts it). The forwarder
# reaches local previews the user enabled.
RUN useradd -m dot && mkdir -p /home/dot/profile /home/dot/Downloads && chown -R dot /home/dot
COPY start.sh /start.sh
COPY forward.py /usr/local/bin/chatterbox-forward
RUN chmod +x /start.sh /usr/local/bin/chatterbox-forward
# Chatterbox compares this to know when to rebuild.
LABEL chatterbox.computer.version="2"

USER dot
EXPOSE 6080 8931
CMD ["/start.sh"]

# OpenCode Server + Telegram Bot — Coolify deploy image
# Goal: smartphone-first uncompromised dev env (all GitHub repos via gh CLI lazy clone)
FROM node:20-alpine

# System deps
#   git/openssh    : repo ops
#   github-cli     : on-demand `gh repo clone owner/repo`
#   curl           : opencode installer + health checks + slack notify
#   bash/tini      : entrypoint orchestration + PID 1 zombie reaping
#   coreutils      : `du -sh` for LRU prune disk math
#   jq             : parse opencode/gh JSON responses
#   python3/make/g++/sqlite-dev : build deps for better-sqlite3 native module (telegram bot)
RUN apk add --no-cache \
      git \
      openssh-client \
      github-cli \
      curl \
      bash \
      ca-certificates \
      tini \
      coreutils \
      jq \
      python3 \
      make \
      g++ \
      sqlite-dev

# OpenCode CLI (sst/opencode)
RUN curl -fsSL https://opencode.ai/install | bash \
    && ln -s /root/.opencode/bin/opencode /usr/local/bin/opencode \
    && opencode --version

# Telegram bot — must build native better-sqlite3 (no prebuilt for Alpine musl)
# Verify the binary exists after install (fail build if missing)
RUN npm install -g @grinev/opencode-telegram-bot \
    && which opencode-telegram \
    && opencode-telegram --help | head -3

WORKDIR /app
COPY scripts/ /app/scripts/
COPY opencode.json /app/opencode.json
RUN chmod +x /app/scripts/*.sh

# Telegram bot uses outbound polling — no inbound port.
# OpenCode serve binds 127.0.0.1 only.
EXPOSE 4096

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/scripts/entrypoint.sh"]

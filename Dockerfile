# OpenCode Server + Telegram Bot — Coolify deploy image
# Goal: smartphone-first uncompromised dev env (all GitHub repos via gh CLI lazy clone)
FROM node:20-alpine

# System deps
#   git/openssh : repo ops
#   github-cli  : on-demand `gh repo clone owner/repo` from natural-language requests
#   curl        : opencode installer + health checks + slack notify
#   bash/tini   : entrypoint orchestration + PID 1 zombie reaping
#   coreutils   : `du -sh` for LRU prune disk math
#   jq          : parse opencode/gh JSON responses inside entrypoint
RUN apk add --no-cache \
      git \
      openssh-client \
      github-cli \
      curl \
      bash \
      ca-certificates \
      tini \
      coreutils \
      jq

# OpenCode CLI (sst/opencode)
RUN curl -fsSL https://opencode.ai/install | bash \
    && ln -s /root/.opencode/bin/opencode /usr/local/bin/opencode \
    && opencode --version

# Pre-warm Telegram bot package
RUN npm install -g @grinev/opencode-telegram-bot || true

WORKDIR /app
COPY scripts/ /app/scripts/
COPY opencode.json /app/opencode.json
RUN chmod +x /app/scripts/*.sh

# Telegram bot uses outbound polling — no inbound port.
# OpenCode serve binds 127.0.0.1 only.
EXPOSE 4096

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/scripts/entrypoint.sh"]

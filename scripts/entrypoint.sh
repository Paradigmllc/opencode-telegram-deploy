#!/usr/bin/env bash
# OpenCode + Telegram Bot orchestration
# Boots opencode serve on 127.0.0.1:4096, then launches the Telegram bot.
# Smartphone-first: lazy clone, LRU prune, Slack notify.
set -euo pipefail

log() { printf "[entrypoint %s] %s\n" "$(date +%H:%M:%S)" "$*"; }

require_env() {
  local var="$1"
  if [ -z "${!var:-}" ]; then
    log "FATAL: $var is not set"
    exit 1
  fi
}

require_env TELEGRAM_BOT_TOKEN
require_env TELEGRAM_ALLOWED_USER_ID
require_env OPENROUTER_API_KEY
require_env GITHUB_TOKEN

# === git identity ===
git config --global user.name  "${GIT_USER_NAME:-Paradigm OpenCode Bot}"
git config --global user.email "${GIT_USER_EMAIL:-bot@paradigm.local}"
git config --global init.defaultBranch main
git config --global --add safe.directory '*'
git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

# === gh CLI auth (enables on-demand `gh repo clone`) ===
echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null || true
gh auth status 2>&1 | head -3 | sed 's/^/[gh] /'

mkdir -p /workspaces /workspaces/.lru
cd /workspaces

# === Boot favorites (optional auto-clone for active projects) ===
if [ -n "${WORKSPACES_REPOS:-}" ]; then
  IFS=',' read -ra REPOS <<< "$WORKSPACES_REPOS"
  for repo in "${REPOS[@]}"; do
    repo="${repo// /}"  # strip spaces
    [ -z "$repo" ] && continue
    name="$(basename "$repo")"
    if [ ! -d "/workspaces/$name/.git" ]; then
      log "Boot-clone $repo …"
      gh repo clone "$repo" "/workspaces/$name" -- --depth 50 --quiet \
        2>&1 | sed 's/^/[gh-clone] /' || log "WARN: clone $repo failed (continuing)"
    fi
    date +%s > "/workspaces/.lru/$name"
  done
fi

# === Always make dotfiles-private available — agent reads CLAUDE.md from it ===
if [ ! -d /workspaces/dotfiles-private/.git ]; then
  log "Boot-clone dotfiles-private (required for AGENT_GUIDANCE)"
  gh repo clone "Paradigmllc/dotfiles" /workspaces/dotfiles-private -- --depth 30 --quiet \
    2>&1 | sed 's/^/[gh-clone] /' || true
fi

# === Disk pressure check ===
USAGE=$(df -P /workspaces | awk 'NR==2 {sub(/%/,"",$5); print $5}')
log "Workspace disk usage: ${USAGE}%"
if [ "${USAGE:-0}" -gt 75 ]; then
  log "Disk >75%, running LRU prune"
  bash /app/scripts/lru-prune.sh || true
fi

# === Slack startup notification (optional) ===
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  curl -sS -X POST -H 'Content-Type: application/json' \
    -d "{\"text\":\"📱 OpenCode Telegram Bot 起動 (host: $(hostname), repos: $(ls /workspaces | grep -v '^\.' | wc -l))\"}" \
    "$SLACK_WEBHOOK_URL" > /dev/null || true
fi

# === Start OpenCode server (loopback only) ===
log "Starting opencode serve …"
cd /workspaces
opencode serve --hostname 127.0.0.1 --port 4096 \
  > /var/log/opencode.log 2>&1 &
OPENCODE_PID=$!

for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:4096/app" > /dev/null 2>&1; then
    log "opencode serve ready (pid=$OPENCODE_PID)"
    break
  fi
  if ! kill -0 "$OPENCODE_PID" 2>/dev/null; then
    log "FATAL: opencode serve died during boot"
    tail -50 /var/log/opencode.log || true
    exit 1
  fi
  sleep 1
done

# === Graceful shutdown ===
shutdown() {
  log "SIGTERM received, stopping children"
  kill -TERM "$OPENCODE_PID" 2>/dev/null || true
  kill -TERM "$BOT_PID"      2>/dev/null || true
  wait
  exit 0
}
trap shutdown SIGTERM SIGINT

# === Start Telegram bot ===
# Env vars consumed by @grinev/opencode-telegram-bot:
#   TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USER_ID, OPENCODE_API_URL,
#   OPENCODE_MODEL_PROVIDER, OPENCODE_MODEL_ID
export OPENCODE_API_URL="http://127.0.0.1:4096"
export OPENCODE_MODEL_PROVIDER="${OPENCODE_MODEL_PROVIDER:-openrouter}"
export OPENCODE_MODEL_ID="${OPENCODE_MODEL_ID:-deepseek-v4-pro}"
export OPEN_BROWSER_ROOTS="${OPEN_BROWSER_ROOTS:-/workspaces}"

# Bot loads config from $XDG_CONFIG_HOME/opencode-telegram-bot/.env (default ~/.config/...).
# Pre-create it so the interactive wizard never runs (TTY not available in container).
APP_HOME="${OPENCODE_TELEGRAM_HOME:-/root/.config/opencode-telegram-bot}"
mkdir -p "$APP_HOME"
cat > "$APP_HOME/.env" <<EOF
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_ALLOWED_USER_ID=$TELEGRAM_ALLOWED_USER_ID
OPENCODE_API_URL=$OPENCODE_API_URL
OPENCODE_MODEL_PROVIDER=$OPENCODE_MODEL_PROVIDER
OPENCODE_MODEL_ID=$OPENCODE_MODEL_ID
OPEN_BROWSER_ROOTS=$OPEN_BROWSER_ROOTS
SALES_OS_AGENT_WEBHOOK_URL=${SALES_OS_AGENT_WEBHOOK_URL:-}
SALES_OS_AGENT_WEBHOOK_SECRET=${SALES_OS_AGENT_WEBHOOK_SECRET:-}
EOF
chmod 600 "$APP_HOME/.env"
# Bot also expects a settings.json — minimal placeholder makes the "configured" check pass
cat > "$APP_HOME/settings.json" <<'EOF'
{"configured": true}
EOF
log "Pre-seeded $APP_HOME/.env + settings.json (skips interactive wizard)"

log "Deleting any existing Telegram webhook to prevent 409 Conflict loops …"
curl -sS -m 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook" >/dev/null 2>&1 || log "WARN: Failed to delete Telegram webhook"

log "Starting opencode-telegram (provider=$OPENCODE_MODEL_PROVIDER, model=$OPENCODE_MODEL_ID) …"
opencode-telegram start --mode installed 2>&1 | sed 's/^/[bot] /' &
BOT_PID=$!

# Wait for first child to exit, then shutdown
wait -n "$OPENCODE_PID" "$BOT_PID"
EXIT_CODE=$?
log "Child exited (code=$EXIT_CODE), triggering shutdown"
shutdown

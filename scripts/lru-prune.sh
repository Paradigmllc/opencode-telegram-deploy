#!/usr/bin/env bash
# LRU prune — remove least-recently-touched repos until disk <60%.
# Touch timestamps live in /workspaces/.lru/<repo_name>.
# Repos with uncommitted changes are NEVER deleted (safety).
set -euo pipefail

THRESHOLD_OK=60
LRU_DIR=/workspaces/.lru

current_usage() {
  df -P /workspaces | awk 'NR==2 {sub(/%/,"",$5); print $5}'
}

has_uncommitted() {
  local repo="$1"
  ( cd "$repo" && [ -n "$(git status --porcelain 2>/dev/null)" ] )
}

unstaged_protected=()

# List repos sorted by LRU touch time (oldest first)
mapfile -t candidates < <(
  find /workspaces -maxdepth 1 -mindepth 1 -type d ! -name '.lru' \
    -printf '%f\n' \
    | while read -r name; do
        ts="$(cat "$LRU_DIR/$name" 2>/dev/null || echo 0)"
        printf "%s\t%s\n" "$ts" "$name"
      done \
    | sort -n \
    | awk -F'\t' '{print $2}'
)

for name in "${candidates[@]}"; do
  usage="$(current_usage)"
  [ "${usage:-0}" -le "$THRESHOLD_OK" ] && break

  repo="/workspaces/$name"
  if has_uncommitted "$repo"; then
    unstaged_protected+=("$name")
    continue
  fi

  printf "[lru-prune] removing %s (disk=%s%%)\n" "$repo" "$usage"
  rm -rf "$repo"
  rm -f "$LRU_DIR/$name"
done

final="$(current_usage)"
printf "[lru-prune] done. final disk=%s%% (target <%s%%)\n" "$final" "$THRESHOLD_OK"

if [ "${#unstaged_protected[@]}" -gt 0 ]; then
  printf "[lru-prune] protected (uncommitted changes): %s\n" "${unstaged_protected[*]}"
fi

# If still over threshold, alert via Slack
if [ "${final:-0}" -gt "$THRESHOLD_OK" ] && [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  curl -sS -X POST -H 'Content-Type: application/json' \
    -d "{\"text\":\"⚠️ OpenCode Telegram: LRU prune 後もディスク ${final}%。Coolify Volume 拡張を検討してください。\"}" \
    "$SLACK_WEBHOOK_URL" > /dev/null || true
fi

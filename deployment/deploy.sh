#!/usr/bin/env bash
# Deploys to the main server in one command (E6), from this checkout:
#
#   deployment/deploy.sh map-management user-management   # those services
#   deployment/deploy.sh gateway                          # nginx.conf, the admin web app
#   deployment/deploy.sh --rollback map-management        # back to the image before
#
# Each service's previous image is kept as :prev, so a rollback is one command
# too. Always recreates the gateway afterwards: nginx looks up the services'
# addresses once, at start, and recreating services shuffles them (on
# 2026-11-08 map requests went to another service for 5 minutes). Ends with one
# line: OK, or what failed. Never copies a .env, except the admin web app's own,
# which holds only public settings.
set -euo pipefail

HOST="${DEPLOY_HOST:-ec2-user@i-08ee7be989aa9721f}"
URL="${DEPLOY_URL:-https://184-195-103-237.sslip.io}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES=(user-management map-management route-management navigation-management
  data-collection ai-training positioning)
EXCLUDES=(--exclude .venv --exclude .env --exclude __pycache__
  --exclude .pytest_cache --exclude .ruff_cache)
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

fail() {
  echo "FAILED: $1" >&2
  tail -20 "$LOG" >&2
  exit 1
}

remote() { ssh -n -o LogLevel=ERROR "$HOST" "cd ~/4u && $1" >>"$LOG" 2>&1; }

rollback=false
if [[ "${1:-}" == "--rollback" ]]; then
  rollback=true
  shift
fi
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [--rollback] service... (or gateway)" >&2
  exit 2
fi

services=()
gateway=false
for name in "$@"; do
  if [[ "$name" == gateway ]]; then
    gateway=true
  elif [[ " ${SERVICES[*]} " == *" $name "* ]]; then
    services+=("$name")
  else
    echo "Unknown service: $name (one of: ${SERVICES[*]} gateway)" >&2
    exit 2
  fi
done

if $rollback; then
  $gateway && fail "the gateway is config files: roll it back by deploying the old checkout"
  for name in "${services[@]}"; do
    remote "sudo docker image inspect 4u-$name:prev >/dev/null" ||
      fail "no previous image of $name to go back to"
    remote "sudo docker tag 4u-$name:prev 4u-$name:latest"
  done
  remote "sudo docker compose up -d --no-build --force-recreate ${services[*]}" ||
    fail "starting the previous images"
else
  if ((${#services[@]})); then
    rsync -az "${EXCLUDES[@]}" "$REPO/packages" "$HOST:4u/" >>"$LOG" 2>&1 || fail "copying packages"
    rsync -az "$REPO/docker-compose.yml" "$HOST:4u/" >>"$LOG" 2>&1 || fail "copying docker-compose.yml"
    for name in "${services[@]}"; do
      rsync -az "${EXCLUDES[@]}" "$REPO/backend-$name/" "$HOST:4u/backend-$name/" >>"$LOG" 2>&1 ||
        fail "copying $name"
      # Keep what's running now as :prev, for --rollback.
      remote "! sudo docker image inspect 4u-$name:latest >/dev/null 2>&1 ||
        sudo docker tag 4u-$name:latest 4u-$name:prev"
    done
    remote "sudo docker compose up -d --build ${services[*]}" || fail "building or starting"
  fi
  if $gateway; then
    rsync -az --include 'admin-web/assets/.env' "${EXCLUDES[@]}" \
      "$REPO/gateway/" "$HOST:4u/gateway/" >>"$LOG" 2>&1 || fail "copying the gateway"
  fi
fi

remote "sudo docker compose up -d --force-recreate gateway" || fail "recreating the gateway"
# Only dangling images: a replaced :prev goes, the current :prev stays.
remote "sudo docker image prune -f >/dev/null && sudo docker builder prune -f >/dev/null" || true

# A service can take a while to load (ai-training loads its model first).
for path in user/ map/ route/ navigation/ data-collection/ ai-training/ positioning/ admin/assets/.env; do
  for attempt in $(seq 1 30); do
    code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$URL/$path" || true)"
    [[ "$code" == 200 ]] && break
    [[ "$attempt" == 30 ]] && fail "$URL/$path answers $code"
    sleep 3
  done
done

what="$*"
$rollback && what="rollback of $what"
echo "OK: $what ($(git -C "$REPO" rev-parse --short HEAD)), every service answers"

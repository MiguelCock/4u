#!/usr/bin/env bash
# The behavior test suite (E3), from a clean state, on this computer only:
#
#   scripts/e2e.sh            # start everything, run e2e/, leave it running
#   scripts/e2e.sh down       # stop it all
#
# Needs Docker and the Supabase CLI (`supabase`, or SUPABASE_CLI=/path/to/it).
# Every run rebuilds the database from db_schema/ and starts the services and
# Qdrant fresh, so results never depend on an earlier run. Nothing here reads
# a service's .env or reaches production: see docker-compose.e2e.yml.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPABASE_CLI="${SUPABASE_CLI:-supabase}"
COMPOSE=(docker compose -p eyes4u-e2e -f "$REPO/docker-compose.yml" -f "$REPO/docker-compose.e2e.yml")
export E2E_GATEWAY_PORT="${E2E_GATEWAY_PORT:-18000}"

cd "$REPO"

# docker-compose.yml names each service's .env, and Compose checks they exist
# before docker-compose.e2e.yml's `!reset` drops them. Where one is missing (as
# in CI), an empty one stands in. An existing .env is never touched, and is
# never read either.
for service_dir in backend-*/ qdrant/; do
  [[ -e "$service_dir.env" ]] || : > "$service_dir.env"
done

if [[ "${1:-}" == "down" ]]; then
  E2E_SERVICE_ROLE_KEY=unused "${COMPOSE[@]}" down --remove-orphans
  "$SUPABASE_CLI" stop --no-backup
  exit 0
fi

echo "== Supabase's local stack"
"$SUPABASE_CLI" start >/dev/null
eval "$("$SUPABASE_CLI" status -o env 2>/dev/null |
  grep -E '^(SERVICE_ROLE_KEY|PUBLISHABLE_KEY|ANON_KEY)=')"
export E2E_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"
export E2E_PUBLISHABLE_KEY="${PUBLISHABLE_KEY:-$ANON_KEY}"
export E2E_GATEWAY_URL="http://127.0.0.1:$E2E_GATEWAY_PORT"
export E2E_SUPABASE_URL="http://127.0.0.1:54321"

echo "== Database, from db_schema/"
"$REPO/scripts/e2e_db.sh"

echo "== Services, fresh"
# Down first: Qdrant starts empty, and ai-training and positioning forget what
# they cached about the last run.
"${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d --build --quiet-pull

echo "== Waiting for every service"
for service in user map route navigation positioning ai-training data-collection; do
  for attempt in $(seq 1 60); do
    if curl -sf -m 5 -o /dev/null "$E2E_GATEWAY_URL/$service/"; then
      break
    fi
    if [[ "$attempt" == 60 ]]; then
      echo "$service didn't start:" >&2
      case "$service" in
        user | map | route | navigation) name="$service-management" ;;
        *) name="$service" ;;
      esac
      "${COMPOSE[@]}" logs --tail 40 "$name" >&2 || true
      exit 1
    fi
    sleep 2
  done
done

echo "== e2e/"
cd "$REPO/e2e"
uv run pytest "${@}"

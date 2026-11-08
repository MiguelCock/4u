#!/usr/bin/env bash
# Builds the e2e database from db_schema/ (E3, e2e/README.md): every table file
# in dependency order, then the storage buckets the services use. Stops at the
# first error, so a schema the files can't rebuild fails the suite. Runs against
# Supabase's local stack only (supabase start), never production.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_CONTAINER="${E2E_DB_CONTAINER:-supabase_db_eyes4u-e2e}"

# Parents before children: each file references only tables listed before it.
TABLES=(
  places
  buildings
  location_type
  roles
  profiles
  anchor_points
  anchor_point_photos
  anchor_point_connections
  routes
  navigation_sessions
  navigation_logs
  user_feedback
  guidance_reports
  photos
  map_deletions
)

psql_e2e() {
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 "$@"
}

if ! docker inspect "$DB_CONTAINER" >/dev/null 2>&1; then
  echo "No $DB_CONTAINER: run 'supabase start' first." >&2
  exit 1
fi

# Every table file must be listed, so a new one can't be silently left out.
for file in "$REPO"/db_schema/*.sql; do
  name="$(basename "$file" .sql)"
  if [[ ! " ${TABLES[*]} " =~ " $name " ]]; then
    echo "db_schema/$name.sql isn't in scripts/e2e_db.sh's list." >&2
    exit 1
  fi
done

echo "Rebuilding the public schema from db_schema/"
psql_e2e -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;
  GRANT ALL ON SCHEMA public TO postgres, anon, authenticated, service_role;
  GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;"
for table in "${TABLES[@]}"; do
  echo "  $table"
  psql_e2e < "$REPO/db_schema/$table.sql"
done

echo "Storage buckets"
psql_e2e -c "INSERT INTO storage.buckets (id, name, public) VALUES
  ('anchor-points', 'anchor-points', true),
  ('Photo', 'Photo', true),
  ('navigation-frames', 'navigation-frames', true)
  ON CONFLICT (id) DO NOTHING;"

# PostgREST caches the schema; tell it to read the new one.
psql_e2e -c "NOTIFY pgrst, 'reload schema';"
echo "Done."

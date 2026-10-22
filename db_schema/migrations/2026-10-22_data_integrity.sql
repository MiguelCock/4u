-- Data-consistency fixes from the CRUD audit.
--
-- 1. anchor_point_connections.distance_manual: true when an admin typed the
--    distance in the connection form. Moving an anchor point recomputes the
--    distance of its *other* connections and leaves these alone.
-- 2. One route per (start, end) pair: concurrent "find route" requests
--    could insert duplicates. Duplicates are removed first, keeping the
--    oldest one (sessions pointing at a removed duplicate are re-pointed).
-- 3. updated_at is kept current on places, buildings, anchor points and
--    routes (nothing ever set it after the insert).
--
-- Run once in the Supabase SQL editor, after 2026-10-22_delete_rules.sql.
-- Safe to re-run.

BEGIN;

-- 1
ALTER TABLE anchor_point_connections
    ADD COLUMN IF NOT EXISTS distance_manual BOOLEAN NOT NULL DEFAULT false;

-- 2
WITH ranked AS (
    SELECT id,
           first_value(id) OVER (
               PARTITION BY start_anchor_id, end_anchor_id
               ORDER BY created_at, id
           ) AS keep_id
    FROM routes
)
UPDATE navigation_sessions s
SET route_id = r.keep_id
FROM ranked r
WHERE s.route_id = r.id AND r.id <> r.keep_id;

DELETE FROM routes r
USING routes older
WHERE r.start_anchor_id = older.start_anchor_id
  AND r.end_anchor_id = older.end_anchor_id
  AND (older.created_at, older.id::text) < (r.created_at, r.id::text);

CREATE UNIQUE INDEX IF NOT EXISTS routes_start_end_unique
    ON routes (start_anchor_id, end_anchor_id);

-- 3
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS places_set_updated_at ON places;
CREATE TRIGGER places_set_updated_at BEFORE UPDATE ON places
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS buildings_set_updated_at ON buildings;
CREATE TRIGGER buildings_set_updated_at BEFORE UPDATE ON buildings
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS anchor_points_set_updated_at ON anchor_points;
CREATE TRIGGER anchor_points_set_updated_at BEFORE UPDATE ON anchor_points
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS routes_set_updated_at ON routes;
CREATE TRIGGER routes_set_updated_at BEFORE UPDATE ON routes
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;

-- A5 (#201): lets admins' screens fetch only what changed since they last
-- looked (backend-map-management's GET /changes), instead of reading all five
-- lists after every edit. Additive: code from before this ignores it.
--
-- Run once in the Supabase SQL editor, before deploying the code that uses it.
-- Check afterwards:
--
--   SELECT
--     (SELECT count(*) FROM information_schema.columns
--       WHERE table_name IN ('anchor_point_photos', 'anchor_point_connections')
--         AND column_name = 'updated_at') AS updated_at_columns,   -- 2
--     (SELECT count(*) FROM pg_trigger
--       WHERE tgname LIKE '%_record_deletion') AS deletion_triggers;  -- 5

BEGIN;

-- Photos and connections had no updated_at, so a change to one couldn't be
-- found without reading them all. Existing rows get the time of this migration.
ALTER TABLE anchor_point_photos
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE anchor_point_connections
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

DROP TRIGGER IF EXISTS anchor_point_photos_set_updated_at ON anchor_point_photos;
CREATE TRIGGER anchor_point_photos_set_updated_at BEFORE UPDATE ON anchor_point_photos
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS anchor_point_connections_set_updated_at ON anchor_point_connections;
CREATE TRIGGER anchor_point_connections_set_updated_at BEFORE UPDATE ON anchor_point_connections
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX IF NOT EXISTS idx_anchor_points_updated_at ON anchor_points (updated_at);
CREATE INDEX IF NOT EXISTS idx_anchor_point_photos_updated_at ON anchor_point_photos (updated_at);
CREATE INDEX IF NOT EXISTS idx_anchor_point_connections_updated_at
    ON anchor_point_connections (updated_at);

-- A deleted row leaves no trace to find, so a trigger notes each one, including
-- those removed by a cascade (deleting a building removes its points and their
-- photos). GET /changes deletes entries older than a day.
CREATE TABLE IF NOT EXISTS map_deletions (
    id BIGSERIAL PRIMARY KEY,
    table_name TEXT NOT NULL,
    row_id UUID NOT NULL,
    deleted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_map_deletions_deleted_at ON map_deletions (deleted_at);
-- No policies: only the services, with the service-role key, may read it.
ALTER TABLE map_deletions ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION record_map_deletion() RETURNS trigger AS $$
BEGIN
    INSERT INTO map_deletions (table_name, row_id) VALUES (TG_TABLE_NAME, OLD.id);
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    name TEXT;
BEGIN
    FOREACH name IN ARRAY ARRAY[
        'places', 'buildings', 'anchor_points',
        'anchor_point_photos', 'anchor_point_connections'
    ] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', name || '_record_deletion', name);
        EXECUTE format(
            'CREATE TRIGGER %I AFTER DELETE ON %I FOR EACH ROW EXECUTE FUNCTION record_map_deletion()',
            name || '_record_deletion', name
        );
    END LOOP;
END;
$$;

COMMIT;

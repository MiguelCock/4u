-- Every row deleted from the map's tables, so admins' screens can drop it
-- without reloading everything (backend-map-management's GET /changes, A5).
-- Filled by the *_record_deletion triggers, cascades included. Entries older
-- than a day are removed by GET /changes. Created by
-- migrations/2026-11-07_map_changes.sql.
CREATE TABLE map_deletions (
    id BIGSERIAL PRIMARY KEY,
    table_name TEXT NOT NULL,
    row_id UUID NOT NULL,
    deleted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_map_deletions_deleted_at ON map_deletions (deleted_at);

-- No policies: only the services, with the service-role key, may read it.
ALTER TABLE map_deletions ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION record_map_deletion() RETURNS trigger AS $$
BEGIN
    INSERT INTO map_deletions (table_name, row_id) VALUES (TG_TABLE_NAME, OLD.id);
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER places_record_deletion AFTER DELETE ON places
    FOR EACH ROW EXECUTE FUNCTION record_map_deletion();
CREATE TRIGGER buildings_record_deletion AFTER DELETE ON buildings
    FOR EACH ROW EXECUTE FUNCTION record_map_deletion();
CREATE TRIGGER anchor_points_record_deletion AFTER DELETE ON anchor_points
    FOR EACH ROW EXECUTE FUNCTION record_map_deletion();
CREATE TRIGGER anchor_point_photos_record_deletion AFTER DELETE ON anchor_point_photos
    FOR EACH ROW EXECUTE FUNCTION record_map_deletion();
CREATE TRIGGER anchor_point_connections_record_deletion AFTER DELETE ON anchor_point_connections
    FOR EACH ROW EXECUTE FUNCTION record_map_deletion();

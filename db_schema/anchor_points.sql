CREATE TABLE anchor_points (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    building_id UUID NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    location_type_id SMALLINT REFERENCES location_type(id),
    floor SMALLINT NOT NULL DEFAULT 0,
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    altitude FLOAT4,
    location_description TEXT,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'verified', 'rejected')),
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
-- A GiST index on two plain DOUBLE PRECISION columns needs btree_gist.
-- It speeds up range filters on latitude/longitude, not radius searches:
-- if the backend ever queries by distance in SQL, PostGIS (a geography
-- column with its own GiST index) is the right tool. Photo search by radius
-- happens in Qdrant instead (backend-ai-training's GeoRadius filter).
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE INDEX idx_anchor_points_location ON anchor_points USING GiST (latitude, longitude);
CREATE INDEX idx_anchor_points_building_floor ON anchor_points (building_id, floor);
CREATE INDEX idx_anchor_points_location_type ON anchor_points (location_type_id);

CREATE TRIGGER anchor_points_set_updated_at BEFORE UPDATE ON anchor_points
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

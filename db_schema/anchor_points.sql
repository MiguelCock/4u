CREATE TABLE anchor_points (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    building_id UUID NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    location_type_id SMALLINT REFERENCES location_type(id),
    floor SMALLINT NOT NULL DEFAULT 0,
    latitude FLOAT4 NOT NULL,
    longitude FLOAT4 NOT NULL,
    altitude FLOAT4,
    location_description TEXT,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'verified', 'rejected')),
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_anchor_points_location ON anchor_points USING GiST (latitude, longitude);
CREATE INDEX idx_anchor_points_building_floor ON anchor_points (building_id, floor);
CREATE INDEX idx_anchor_points_location_type ON anchor_points (location_type_id);

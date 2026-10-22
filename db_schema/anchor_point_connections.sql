CREATE TABLE anchor_point_connections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    anchor_point_a_id UUID NOT NULL REFERENCES anchor_points(id) ON DELETE CASCADE,
    anchor_point_b_id UUID NOT NULL REFERENCES anchor_points(id) ON DELETE CASCADE,
    distance_meters FLOAT4,
    -- True when an admin typed the distance; moving a point only
    -- recomputes the distances of its other connections.
    distance_manual BOOLEAN NOT NULL DEFAULT false,
    notes TEXT,
    created_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CHECK (anchor_point_a_id::text < anchor_point_b_id::text),
    UNIQUE (anchor_point_a_id, anchor_point_b_id)
);

-- Indexes
CREATE INDEX idx_anchor_point_connections_a ON anchor_point_connections (anchor_point_a_id);
CREATE INDEX idx_anchor_point_connections_b ON anchor_point_connections (anchor_point_b_id);

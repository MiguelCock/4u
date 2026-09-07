routes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    building_id UUID NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    start_anchor_id UUID NOT NULL REFERENCES anchor_points(id),
    end_anchor_id UUID NOT NULL REFERENCES anchor_points(id),
    waypoint_anchor_ids UUID[] DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
)

-- Indexes
CREATE INDEX idx_routes_building ON routes (building_id);

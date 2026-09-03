navigation_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    building_id UUID NOT NULL REFERENCES buildings(id),
    route_id UUID REFERENCES routes(id),
    start_time TIMESTAMPTZ DEFAULT NOW(),
    end_time TIMESTAMPTZ,
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'completed', 'abandoned', 'failed')),
    start_position JSONB,
    end_position JSONB,
    device_info JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
)

-- Indexes
CREATE INDEX idx_navigation_sessions_user ON navigation_sessions (user_id);
CREATE INDEX idx_navigation_sessions_building ON navigation_sessions (building_id);
CREATE INDEX idx_navigation_sessions_status ON navigation_sessions (status);
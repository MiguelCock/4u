-- "Wrong instruction" reports made by an admin during a test trip (the
-- red X in NavigationScreen's admin preview). Owned by
-- backend-navigation-management; shown as X marks on the session's map.
CREATE TABLE guidance_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES navigation_sessions(id) ON DELETE CASCADE,
    reported_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    -- What the app had just said, and which kind of cue it was (turn,
    -- start_walking, leg, meters_ahead, arrival...).
    instruction_text TEXT,
    cue_type TEXT,
    waypoint_index SMALLINT,
    gps_lat DOUBLE PRECISION,
    gps_long DOUBLE PRECISION,
    corrected_lat DOUBLE PRECISION,
    corrected_long DOUBLE PRECISION,
    compass_heading FLOAT4,
    debug JSONB
);

-- Indexes
CREATE INDEX idx_guidance_reports_session ON guidance_reports (session_id);

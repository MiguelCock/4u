CREATE TABLE navigation_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES navigation_sessions(id) ON DELETE CASCADE,
    timestamp TIMESTAMPTZ DEFAULT NOW(),
    gps_lat DOUBLE PRECISION NOT NULL,
    gps_long DOUBLE PRECISION NOT NULL,
    gps_accuracy FLOAT4,
    heading FLOAT4,
    corrected_lat DOUBLE PRECISION,
    corrected_long DOUBLE PRECISION,
    correction_error FLOAT4,
    anchor_match_id UUID REFERENCES anchor_points(id) ON DELETE SET NULL,
    confidence_score FLOAT4 CHECK (confidence_score BETWEEN 0 AND 1),
    raw_image_url TEXT,
    -- Per-tick diagnostics for tuning the correction and guidance (match
    -- candidates, gating decisions, compass heading, spoken cue...).
    debug JSONB
);

-- Indexes
CREATE INDEX idx_navigation_logs_session ON navigation_logs (session_id);
CREATE INDEX idx_navigation_logs_timestamp ON navigation_logs (timestamp DESC);

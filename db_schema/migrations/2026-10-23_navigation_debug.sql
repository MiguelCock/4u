-- Diagnostics for tuning the GPS correction and turn guidance.
--
-- 1. navigation_logs.debug: per-tick detail the fixed columns don't hold -
--    the correction's candidates and why a match was used or rejected,
--    the compass heading, which position guidance used, the cue spoken.
--    Free-form JSON so it can grow without more migrations.
-- 2. guidance_reports: an admin testing the user flow taps "Wrong
--    instruction" when the app says something wrong; the instruction and
--    where it happened are stored and shown as an X on the session's map.
--
-- Run once in the Supabase SQL editor. Safe to re-run.

BEGIN;

ALTER TABLE navigation_logs ADD COLUMN IF NOT EXISTS debug JSONB;

CREATE TABLE IF NOT EXISTS guidance_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES navigation_sessions(id) ON DELETE CASCADE,
    reported_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
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

CREATE INDEX IF NOT EXISTS idx_guidance_reports_session
    ON guidance_reports (session_id);

COMMIT;

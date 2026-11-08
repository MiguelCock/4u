-- E1 (#193): indexes for three foreign keys that had none, found by
-- diagnostics/2026-11-07_e1_report_1_tables_indexes.sql. Without one, deleting
-- a point makes Postgres scan every trip log to clear its anchor_match_id, and
-- trip logs are the only table that grows without limit. The other foreign
-- keys it found point at profiles, places and roles, which are rarely deleted.
--
-- Run once in the Supabase SQL editor, before or after the code: nothing
-- depends on it. To see the difference, run
-- diagnostics/2026-11-07_e1_delete_point_check.sql before and after.

BEGIN;

CREATE INDEX IF NOT EXISTS idx_navigation_logs_anchor_match
    ON navigation_logs (anchor_match_id);
CREATE INDEX IF NOT EXISTS idx_navigation_sessions_route
    ON navigation_sessions (route_id);
CREATE INDEX IF NOT EXISTS idx_routes_end_anchor
    ON routes (end_anchor_id);

COMMIT;

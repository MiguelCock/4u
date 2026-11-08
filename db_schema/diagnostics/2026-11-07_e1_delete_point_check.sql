-- E1 (#193): what deleting a point costs in trip logs. READ-ONLY.
--
-- Deleting a point makes Postgres find its logs, to clear their
-- anchor_match_id. This runs that same lookup, for the point with the most
-- matched logs, without deleting anything. Run it before and after
-- migrations/2026-11-07_foreign_key_indexes.sql, and compare:
--   before: "Seq Scan on navigation_logs", reading every row;
--   after:  a scan "using idx_navigation_logs_anchor_match" (Index, Index Only
--           or Bitmap Index Scan: Postgres picks), reading only that point's logs.
-- The last line, "Execution Time", is the number to compare.

EXPLAIN (ANALYZE, BUFFERS)
SELECT 1
FROM navigation_logs
WHERE anchor_match_id = (
    SELECT anchor_match_id
    FROM navigation_logs
    WHERE anchor_match_id IS NOT NULL
    GROUP BY anchor_match_id
    ORDER BY count(*) DESC
    LIMIT 1
);

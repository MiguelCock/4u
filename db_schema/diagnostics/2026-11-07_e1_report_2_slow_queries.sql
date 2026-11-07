-- E1 (#193), report 2 of 2: the queries that cost the most time. READ-ONLY.
--
-- Needs the pg_stat_statements extension. Supabase usually has it on. If this
-- fails with 'relation "pg_stat_statements" does not exist', turn it on under
-- Database → Extensions → pg_stat_statements, use the app and the admin screens
-- normally for a day, then run this again.
--
-- Run in the Supabase SQL editor, export the result as CSV, and share it.
-- Query texts have their values replaced by $1, $2..., so they hold no data.
--
-- Columns: total time spent on the query since the counters were reset, how
-- many times it ran, its average and worst time, rows returned per call, and
-- the share of its reads served from memory (cache_hit).

SELECT
    round(s.total_exec_time::numeric / 1000, 1) AS total_s,
    s.calls,
    round(s.mean_exec_time::numeric, 1) AS mean_ms,
    round(s.max_exec_time::numeric, 1) AS max_ms,
    round(s.rows::numeric / greatest(s.calls, 1), 1) AS rows_per_call,
    round(
        100.0 * s.shared_blks_hit / nullif(s.shared_blks_hit + s.shared_blks_read, 0),
        1
    ) AS cache_hit_pct,
    left(regexp_replace(s.query, '\s+', ' ', 'g'), 300) AS query
FROM pg_stat_statements s
JOIN pg_roles r ON r.oid = s.userid
-- The app's own traffic, not Supabase's internal housekeeping.
WHERE r.rolname IN ('authenticator', 'service_role', 'authenticated', 'anon', 'postgres')
    AND s.query NOT ILIKE '%pg_stat_statements%'
ORDER BY s.total_exec_time DESC
LIMIT 40;

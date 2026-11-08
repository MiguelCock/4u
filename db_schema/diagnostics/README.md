# Diagnostics

Read-only SQL, run by hand in the Supabase SQL editor to see how the database is used. **They change nothing.** Unlike `migrations/`, they can be run any number of times.

The editor shows only the last statement's result, so each file is one query returning one table. Export it as CSV with "Export" above the results.

| File | Shows |
|---|---|
| `2026-11-07_e1_report_1_tables_indexes.sql` | Table sizes, scans against index use, never-used indexes, and foreign keys with no index (E1, #193) |
| `2026-11-07_e1_report_2_slow_queries.sql` | The 40 queries that took the most total time, from `pg_stat_statements` (E1, #193). Its texts have their values replaced by `$1`, `$2`…, so they hold no data |

Both were run against a local Postgres with every `db_schema/` table, using stand-ins for Supabase's `auth.users` and `auth.uid()`. Even there, report 1 lists foreign keys with no index: `navigation_logs.anchor_match_id`, for example, means deleting a point scans every trip log. The real database's report decides what to add.

## E1's results (2026-11-07)

In `results/`, as exported from the editor. Query texts are Supabase's own, with every value replaced by a placeholder.

- **The database isn't what's slow.** Trip logs are 7 MB in 3,349 rows, and everything else is under 0.5 MB. The app's queries average under 5 ms; the busiest, inserting logs, ran 30,678 times at 0.7 ms. The most total time goes to the Supabase dashboard's own queries. The 1 s waits seen in the load tests are round trips to Supabase (E2), not missing indexes.
- **The photos list was read in full 10,189 times**, by the admin screens. A5's `GET /changes` already cuts that.
- **Nine foreign keys had no index.** `migrations/2026-11-07_foreign_key_indexes.sql` adds the three that cost as data grows: `navigation_logs.anchor_match_id`, which every point delete scans, then `navigation_sessions.route_id` and `routes.end_anchor_id`. The others point at profiles, places and roles, which are rarely deleted. `2026-11-07_e1_delete_point_check.sql` shows the difference, read-only.
- **Trip logs:** at about 9,000 rows per 15-person hour, they take years to reach a size that matters. So the plan is to watch the size, and archive old trips if needed, rather than partition.

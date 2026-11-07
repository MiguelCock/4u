# Diagnostics

Read-only SQL, run by hand in the Supabase SQL editor to see how the database is used. **They change nothing.** Unlike `migrations/`, they can be run any number of times.

The editor shows only the last statement's result, so each file is one query returning one table. Export it as CSV with "Export" above the results.

| File | Shows |
|---|---|
| `2026-11-07_e1_report_1_tables_indexes.sql` | Table sizes, scans against index use, never-used indexes, and foreign keys with no index (E1, #193) |
| `2026-11-07_e1_report_2_slow_queries.sql` | The 40 queries that took the most total time, from `pg_stat_statements` (E1, #193). Its texts have their values replaced by `$1`, `$2`…, so they hold no data |

Both were run against a local Postgres with every `db_schema/` table, using stand-ins for Supabase's `auth.users` and `auth.uid()`. Even there, report 1 lists foreign keys with no index: `navigation_logs.anchor_match_id`, for example, means deleting a point scans every trip log. The real database's report decides what to add.

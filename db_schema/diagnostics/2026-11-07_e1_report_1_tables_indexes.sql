-- E1 (#193), report 1 of 2: tables and indexes. READ-ONLY: it changes nothing.
--
-- Run in the Supabase SQL editor (paste all of it, Run). The editor shows one
-- table; export it as CSV ("Export" above the results) and share it.
--
-- Rows, by section:
--   table       size, rows, and how often it's read by scanning every row
--               (seq_scan) against through an index (idx_scan);
--   index       size and how often it's been used; never-used ones are
--               candidates to drop, unless they enforce uniqueness;
--   fk_no_index a foreign key with no index starting with its column, which
--               makes deletes and joins on it scan the whole table;
--   stats_since when these counters were last reset, so "never used" means
--               "not since then".

WITH tables AS (
    SELECT
        'table' AS section,
        c.relname AS name,
        format(
            'size %s (data %s), %s rows, seq_scan %s (rows read %s), idx_scan %s, inserts %s, updates %s, deletes %s',
            pg_size_pretty(pg_total_relation_size(c.oid)),
            pg_size_pretty(pg_relation_size(c.oid)),
            CASE WHEN c.reltuples < 0 THEN 'unknown' ELSE '~' || c.reltuples::bigint END,
            s.seq_scan, s.seq_tup_read, coalesce(s.idx_scan, 0),
            s.n_tup_ins, s.n_tup_upd, s.n_tup_del
        ) AS detail,
        pg_total_relation_size(c.oid) AS sort_key
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_stat_user_tables s ON s.relid = c.oid
    WHERE n.nspname = 'public' AND c.relkind = 'r'
),
indexes AS (
    SELECT
        'index' AS section,
        s.relname || '.' || s.indexrelname AS name,
        format(
            'size %s, used %s times%s%s',
            pg_size_pretty(pg_relation_size(s.indexrelid)),
            s.idx_scan,
            CASE WHEN i.indisunique THEN ', unique' ELSE '' END,
            CASE WHEN s.idx_scan = 0 AND NOT i.indisunique
                THEN ', NEVER USED' ELSE '' END
        ) AS detail,
        pg_relation_size(s.indexrelid) AS sort_key
    FROM pg_stat_user_indexes s
    JOIN pg_index i ON i.indexrelid = s.indexrelid
    WHERE s.schemaname = 'public'
),
foreign_keys AS (
    SELECT
        'fk_no_index' AS section,
        rel.relname || '.' || att.attname AS name,
        'references ' || confrelid::regclass::text AS detail,
        0::bigint AS sort_key
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = rel.relnamespace
    JOIN pg_attribute att
        ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
    WHERE con.contype = 'f'
        AND n.nspname = 'public'
        AND NOT EXISTS (
            SELECT 1 FROM pg_index i
            WHERE i.indrelid = con.conrelid AND i.indkey[0] = con.conkey[1]
        )
),
since AS (
    SELECT
        'stats_since' AS section,
        'counters reset' AS name,
        coalesce(stats_reset::text, 'never (since the database started)') AS detail,
        0::bigint AS sort_key
    FROM pg_stat_database
    WHERE datname = current_database()
)
SELECT section, name, detail FROM (
    SELECT * FROM since
    UNION ALL SELECT * FROM tables
    UNION ALL SELECT * FROM indexes
    UNION ALL SELECT * FROM foreign_keys
) report
ORDER BY
    array_position(ARRAY['stats_since', 'table', 'index', 'fk_no_index'], section),
    sort_key DESC,
    name;

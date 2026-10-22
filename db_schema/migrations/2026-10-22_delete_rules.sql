-- Let anchor points, buildings, universities and profiles be deleted even
-- when other data refers to them.
--
-- These foreign keys had no ON DELETE rule, so Postgres refused the delete
-- of anything still referenced. Any anchor point used in a test trip (as a
-- route's start/end, or as a camera match in a navigation log) could never
-- be deleted, and that also blocked deleting its building and university.
--
-- New rules: routes go with their start/end points (they're recomputed on
-- demand anyway). Trip history (sessions, logs) and audit columns are kept
-- and just lose the reference (SET NULL).
--
-- Run once in the Supabase SQL editor. Safe to re-run. Constraint names
-- are looked up by column, so it works whatever the existing ones are
-- called.

BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.replace_fk(
    tbl regclass, col name, target text, on_delete text
) RETURNS void AS $$
DECLARE
    existing name;
BEGIN
    FOR existing IN
        SELECT con.conname
        FROM pg_constraint con
        JOIN pg_attribute att
            ON att.attrelid = con.conrelid AND att.attnum = ANY (con.conkey)
        WHERE con.contype = 'f' AND con.conrelid = tbl AND att.attname = col
    LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', tbl, existing);
    END LOOP;
    EXECUTE format(
        'ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %s ON DELETE %s',
        tbl, tbl::text || '_' || col || '_fkey', col, target, on_delete
    );
END;
$$ LANGUAGE plpgsql;

-- Anchor points
SELECT pg_temp.replace_fk('routes', 'start_anchor_id', 'anchor_points(id)', 'CASCADE');
SELECT pg_temp.replace_fk('routes', 'end_anchor_id', 'anchor_points(id)', 'CASCADE');
SELECT pg_temp.replace_fk('navigation_logs', 'anchor_match_id', 'anchor_points(id)', 'SET NULL');

-- Routes and buildings (trip history keeps its rows)
SELECT pg_temp.replace_fk('navigation_sessions', 'route_id', 'routes(id)', 'SET NULL');
ALTER TABLE navigation_sessions ALTER COLUMN building_id DROP NOT NULL;
SELECT pg_temp.replace_fk('navigation_sessions', 'building_id', 'buildings(id)', 'SET NULL');

-- Universities
SELECT pg_temp.replace_fk('profiles', 'place_id', 'places(id)', 'SET NULL');

-- Profiles (audit columns keep the row, lose who made it)
SELECT pg_temp.replace_fk('routes', 'created_by', 'profiles(id)', 'SET NULL');
ALTER TABLE anchor_point_photos ALTER COLUMN captured_by DROP NOT NULL;
SELECT pg_temp.replace_fk('anchor_point_photos', 'captured_by', 'profiles(id)', 'SET NULL');
ALTER TABLE anchor_point_connections ALTER COLUMN created_by DROP NOT NULL;
SELECT pg_temp.replace_fk('anchor_point_connections', 'created_by', 'profiles(id)', 'SET NULL');

COMMIT;

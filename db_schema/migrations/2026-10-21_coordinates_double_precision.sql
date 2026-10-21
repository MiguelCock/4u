-- Store every latitude/longitude as DOUBLE PRECISION instead of FLOAT4.
--
-- FLOAT4 keeps ~7 significant digits. At this campus's longitude (~-75.58)
-- that's a step of ~0.0000076 degrees, about 0.85 m: every saved point
-- snapped onto north-south lines 0.85 m apart, which is why anchor points
-- (e.g. Bloque 13's) looked lined up "in parallel". DOUBLE PRECISION keeps
-- ~15 digits, far below a millimetre.
--
-- Run once in the Supabase SQL editor. It's safe to re-run (a no-op once
-- the columns are already DOUBLE PRECISION). Values already saved keep
-- their snapped position (the lost digits can't be recovered); re-place a
-- point with "Move on map" if it matters. Everything saved from now on
-- keeps full precision. Indexes on these columns are rebuilt automatically.

BEGIN;

ALTER TABLE places
    ALTER COLUMN latitude TYPE DOUBLE PRECISION,
    ALTER COLUMN longitude TYPE DOUBLE PRECISION;

ALTER TABLE buildings
    ALTER COLUMN latitude TYPE DOUBLE PRECISION,
    ALTER COLUMN longitude TYPE DOUBLE PRECISION;

ALTER TABLE anchor_points
    ALTER COLUMN latitude TYPE DOUBLE PRECISION,
    ALTER COLUMN longitude TYPE DOUBLE PRECISION;

ALTER TABLE navigation_logs
    ALTER COLUMN gps_lat TYPE DOUBLE PRECISION,
    ALTER COLUMN gps_long TYPE DOUBLE PRECISION,
    ALTER COLUMN corrected_lat TYPE DOUBLE PRECISION,
    ALTER COLUMN corrected_long TYPE DOUBLE PRECISION;

ALTER TABLE photos
    ALTER COLUMN latitude TYPE DOUBLE PRECISION,
    ALTER COLUMN longitude TYPE DOUBLE PRECISION;

COMMIT;

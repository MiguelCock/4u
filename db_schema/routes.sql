CREATE TABLE routes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Nullable as of the trip-planning work (#80/#81) - a route created
    -- via POST /routes/find_or_create spans whatever buildings its start/
    -- end anchors land in, so this is "the building the trip starts in"
    -- at best, not a hard scope. ON DELETE SET NULL (not CASCADE) so
    -- deleting a building doesn't delete cross-building routes that just
    -- happen to start there.
    building_id UUID REFERENCES buildings(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    -- CASCADE: a route can't exist without its ends (it's recomputed on
    -- demand anyway); sessions keep their history via route_id SET NULL.
    start_anchor_id UUID NOT NULL REFERENCES anchor_points(id) ON DELETE CASCADE,
    end_anchor_id UUID NOT NULL REFERENCES anchor_points(id) ON DELETE CASCADE,
    waypoint_anchor_ids UUID[] DEFAULT '{}',
    -- Audit field - who created this route (any authenticated user can,
    -- not just admins, since trip planning creates one as a side effect
    -- of picking a start/end point). Nullable since rows created before
    -- this column existed have no value.
    created_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_routes_building ON routes (building_id);
-- One route per (start, end) pair; find_or_create relies on it.
CREATE UNIQUE INDEX routes_start_end_unique ON routes (start_anchor_id, end_anchor_id);

CREATE TRIGGER routes_set_updated_at BEFORE UPDATE ON routes
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Migration for an existing live database (this table already has rows on
-- the deployed Phase 1 instance) - apply by hand in the Supabase SQL
-- editor, same "hand-maintained, not a migration tool" convention as
-- every other change in this directory:
--
-- ALTER TABLE routes ALTER COLUMN building_id DROP NOT NULL;
-- ALTER TABLE routes DROP CONSTRAINT IF EXISTS routes_building_id_fkey;
-- ALTER TABLE routes ADD CONSTRAINT routes_building_id_fkey
--     FOREIGN KEY (building_id) REFERENCES buildings(id) ON DELETE SET NULL;
-- ALTER TABLE routes ADD COLUMN created_by UUID REFERENCES profiles(id);

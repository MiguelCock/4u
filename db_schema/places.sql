-- Keeps updated_at current on every UPDATE (used by places, buildings,
-- anchor_points and routes). Defined here because places.sql runs first.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE places (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    address TEXT,
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    radius_km FLOAT4 DEFAULT 5.0,
    timezone TEXT DEFAULT 'UTC',
    website TEXT,
    contact_email TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER places_set_updated_at BEFORE UPDATE ON places
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

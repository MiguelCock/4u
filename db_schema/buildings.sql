buildings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    place_id UUID NOT NULL REFERENCES places(id) ON DELETE CASCADE,
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    address TEXT,
    latitude FLOAT4 NOT NULL,
    longitude FLOAT4 NOT NULL,
    floors INTEGER DEFAULT 1,
    has_elevator BOOLEAN DEFAULT FALSE,
    has_stairs BOOLEAN DEFAULT TRUE,
    opening_hours JSONB DEFAULT '{}',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(place_id, code)
)
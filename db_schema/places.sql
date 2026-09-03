places (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    address TEXT,
    latitude FLOAT4 NOT NULL,
    longitude FLOAT4 NOT NULL,
    radius_km FLOAT4 DEFAULT 5.0,
    timezone TEXT DEFAULT 'UTC',
    website TEXT,
    contact_email TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
)
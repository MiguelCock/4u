profiles (
    id UUID PRIMARY KEY DEFAULT auth.uid(),
    place_id UUID REFERENCES places(id),
    role_id SMALLINT REFERENCES roles(id),
    full_name TEXT,
    avatar_url TEXT,
    phone TEXT,
    preferences JSONB DEFAULT '{"verbosity":"medium","feedback_type":"voice"}',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
)
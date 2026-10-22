CREATE TABLE photos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    accuracy FLOAT4,
    heading FLOAT4,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE photos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    latitude FLOAT4 NOT NULL,
    longitude FLOAT4 NOT NULL,
    accuracy FLOAT4,
    heading FLOAT4,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

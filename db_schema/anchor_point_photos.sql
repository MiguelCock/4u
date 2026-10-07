CREATE TABLE anchor_point_photos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    anchor_point_id UUID NOT NULL REFERENCES anchor_points(id) ON DELETE CASCADE,
    image_url TEXT NOT NULL,
    heading FLOAT4,
    captured_by UUID NOT NULL REFERENCES profiles(id),
    captured_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_anchor_point_photos_anchor_point ON anchor_point_photos (anchor_point_id);

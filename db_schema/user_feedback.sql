user_feedback (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    session_id UUID REFERENCES navigation_sessions(id),
    comment TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
)

-- Indexes
CREATE INDEX idx_user_feedback_user ON user_feedback (user_id);
CREATE INDEX idx_user_feedback_session ON user_feedback (session_id);
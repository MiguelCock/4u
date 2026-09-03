roles (
    id SMALLINT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
)

-- Default values
INSERT INTO roles (id, name) VALUES 
(1, 'user'),
(2, 'admin');
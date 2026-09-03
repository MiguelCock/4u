location_type (
    id SMALLINT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
)

-- Default values
INSERT INTO location_type (id, name, description) VALUES 
(1, 'entrance', 'Building entrance or main door'),
(2, 'intersection', 'Hallway intersection'),
(3, 'elevator', 'Elevator area'),
(4, 'stairwell', 'Staircase area'),
(5, 'classroom', 'Classroom location'),
(6, 'office', 'Office location'),
(7, 'restroom', 'Restroom location'),
(8, 'cafeteria', 'Cafeteria or dining area'),
(9, 'other', 'Other location');
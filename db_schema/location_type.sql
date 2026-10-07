CREATE TABLE location_type (
    id SMALLINT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

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
(9, 'other', 'Other location'),
(10, 'hallway', 'Hallway or corridor segment (not an intersection)'),
(11, 'ramp', 'Accessibility ramp'),
(12, 'outdoor_path', 'Outdoor walkway or path between buildings'),
(13, 'parking', 'Parking area or lot'),
(14, 'lobby', 'Building lobby or atrium'),
(15, 'auditorium', 'Auditorium or large lecture hall'),
(16, 'courtyard', 'Outdoor courtyard or plaza'),
(17, 'crosswalk', 'Pedestrian crosswalk or road crossing'),
(18, 'bus_stop', 'Campus bus or shuttle stop');

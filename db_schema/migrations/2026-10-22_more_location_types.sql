-- Fifteen more location types, so destinations can say what they are
-- (stationery shop, library, infirmary, exit...). Every new one is a
-- destination type: it needs a description and appears in users'
-- destination list (application/lib/services/destinations.dart and
-- backend-map-management's DESTINATION_LOCATION_TYPE_IDS).
--
-- The app groups all types into categories for its picker; that grouping
-- is app logic only, nothing about it is stored here.
--
-- Run once in the Supabase SQL editor. Safe to re-run.

INSERT INTO location_type (id, name, description) VALUES
(19, 'stationery_shop', 'Stationery shop (papelería)'),
(20, 'copy_center', 'Copy and print center'),
(21, 'store', 'Store or minimarket'),
(22, 'atm', 'ATM or bank branch'),
(23, 'library', 'Library'),
(24, 'laboratory', 'Laboratory'),
(25, 'computer_room', 'Computer room'),
(26, 'study_area', 'Study area'),
(27, 'infirmary', 'Infirmary or medical service'),
(28, 'sports_area', 'Gym or sports area'),
(29, 'chapel', 'Chapel'),
(30, 'exit', 'Exit or gate'),
(31, 'bike_parking', 'Bike parking'),
(32, 'waiting_area', 'Waiting area or benches'),
(33, 'drinking_fountain', 'Drinking fountain')
ON CONFLICT (id) DO NOTHING;

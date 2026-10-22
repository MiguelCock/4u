/// Location types (db_schema/location_type.sql ids) that are places people
/// go *to*: entrance, classroom, office, restroom, cafeteria, parking,
/// lobby, auditorium, bus stop. The rest (hallway, intersection, stairs,
/// ramp...) are in-between points that only exist so routes can be
/// connected. Mirrored by `DESTINATION_LOCATION_TYPE_IDS` in
/// backend-map-management/app/models.py - keep the two in sync.
const Set<int> kDestinationLocationTypes = {1, 5, 6, 7, 8, 13, 14, 15, 18};

bool isDestinationType(int? locationTypeId) =>
    kDestinationLocationTypes.contains(locationTypeId);

/// A destination type requires a description (it's the name users pick
/// and hear); in-between points may leave it empty.
bool descriptionRequiredFor(int? locationTypeId) =>
    isDestinationType(locationTypeId);

/// Whether an `anchor_points` row is offered to users as a destination:
/// an important type *and* a name. Hallway-type points never are, so
/// admins don't have to invent names for them.
bool isDestinationAnchor(Map<String, dynamic> anchor) =>
    isDestinationType(anchor['location_type_id'] as int?) &&
    (anchor['location_description'] as String? ?? '').trim().isNotEmpty;

/// Ids of buildings users may navigate in: the building and its university
/// are both active. An admin deactivating either hides its points from the
/// destination list and from start-point selection.
Set<String> activeBuildingIds(
  Iterable<Map<String, dynamic>> places,
  Iterable<Map<String, dynamic>> buildings,
) {
  final activePlaces = {
    for (final p in places)
      if (p['is_active'] != false) p['id'],
  };
  return {
    for (final b in buildings)
      if (b['is_active'] != false && activePlaces.contains(b['place_id']))
        b['id'] as String,
  };
}

/// Which points a map shows for the selected floor. `anchor_points.floor` is
/// 0-based (0 = the ground floor), and a missing floor counts as 0.
library;

/// How a point relates to the floor a map is showing.
enum FloorRelation { current, above, below, hidden }

int pointFloor(Map<String, dynamic> point) => (point['floor'] as int?) ?? 0;

/// The floors [points] are on, lowest first.
List<int> floorsOf(Iterable<Map<String, dynamic>> points) =>
    points.map(pointFloor).toSet().toList()..sort();

/// [selected] within [floors]' range: a filter or a new scope can leave a map
/// on a floor it no longer has. Null with no floors.
int? floorInRange(int selected, List<int> floors) {
  if (floors.isEmpty) return null;
  return selected.clamp(floors.first, floors.last);
}

/// The floor a map opens on: the ground floor if it has one, else its lowest.
int? openingFloor(List<int> floors) {
  if (floors.isEmpty) return null;
  return floors.contains(0) ? 0 : floors.first;
}

/// Only the floor directly above and below are shown besides the selected one,
/// and with [onlySelected] not even those.
FloorRelation floorRelation(
  Map<String, dynamic> point,
  int selected, {
  bool onlySelected = false,
}) {
  final floor = pointFloor(point);
  if (floor == selected) return FloorRelation.current;
  if (onlySelected) return FloorRelation.hidden;
  if (floor == selected + 1) return FloorRelation.above;
  if (floor == selected - 1) return FloorRelation.below;
  return FloorRelation.hidden;
}

/// Whether a map draws the line between [a] and [b]: both visible, and one on
/// the selected floor, so the floors above and below don't clutter it with
/// their own corridors.
bool floorShowsConnection(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
  int selected, {
  bool onlySelected = false,
}) {
  final ra = floorRelation(a, selected, onlySelected: onlySelected);
  final rb = floorRelation(b, selected, onlySelected: onlySelected);
  if (ra == FloorRelation.hidden || rb == FloorRelation.hidden) return false;
  return ra == FloorRelation.current || rb == FloorRelation.current;
}

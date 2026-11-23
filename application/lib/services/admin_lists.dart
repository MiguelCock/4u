/// The admin's five map lists, and what the admin home asks of them
/// (Phase D): who belongs to whom, what a delete takes with it, and each
/// tab's filtering. Pure: no widgets, no requests.
class AdminLists {
  const AdminLists({
    this.places = const [],
    this.buildings = const [],
    this.anchorPoints = const [],
    this.photos = const [],
    this.connections = const [],
  });

  final List<Map<String, dynamic>> places;
  final List<Map<String, dynamic>> buildings;
  final List<Map<String, dynamic>> anchorPoints;
  final List<Map<String, dynamic>> photos;
  final List<Map<String, dynamic>> connections;

  List<Map<String, dynamic>> buildingsOf(String placeId) =>
      buildings.where((b) => b['place_id'] == placeId).toList();

  List<Map<String, dynamic>> anchorPointsOf(String buildingId) =>
      anchorPoints.where((p) => p['building_id'] == buildingId).toList();

  List<Map<String, dynamic>> photosOf(String anchorPointId) =>
      photos.where((p) => p['anchor_point_id'] == anchorPointId).toList();

  List<Map<String, dynamic>> connectionsOf(String anchorPointId) => connections
      .where(
        (c) =>
            c['anchor_point_a_id'] == anchorPointId ||
            c['anchor_point_b_id'] == anchorPointId,
      )
      .toList();

  /// Points with at least one photo, for the filters.
  Set<String> get pointsWithPhotos => {
    for (final photo in photos) photo['anchor_point_id'] as String?,
  }.whereType<String>().toSet();

  /// Points at either end of a connection, for the filters.
  Set<String> get connectedPoints => {
    for (final c in connections) ...[
      c['anchor_point_a_id'] as String?,
      c['anchor_point_b_id'] as String?,
    ],
  }.whereType<String>().toSet();

  /// What deleting university [placeId] takes with it (every table below it
  /// is ON DELETE CASCADE).
  Cascade placeCascade(String placeId) {
    final ofPlace = buildingsOf(placeId);
    final ids = {for (final b in ofPlace) b['id'] as String};
    return _cascade(
      ofPlace,
      anchorPoints.where((p) => ids.contains(p['building_id'])).toList(),
    );
  }

  /// What deleting building [buildingId] takes with it.
  Cascade buildingCascade(String buildingId) =>
      _cascade(const [], anchorPointsOf(buildingId));

  Cascade _cascade(
    List<Map<String, dynamic>> buildings,
    List<Map<String, dynamic>> anchors,
  ) {
    final ids = {for (final p in anchors) p['id'] as String};
    return (
      buildings: buildings,
      anchors: anchors,
      photos: photos.where((ph) => ids.contains(ph['anchor_point_id'])).length,
      connections: connections
          .where(
            (c) =>
                ids.contains(c['anchor_point_a_id']) ||
                ids.contains(c['anchor_point_b_id']),
          )
          .length,
    );
  }

  /// The floors the filters offer: building [buildingId]'s, or the most
  /// any building has.
  int maxFloors(String? buildingId) {
    int floorsOf(Map<String, dynamic> b) => b['floors'] as int? ?? 1;
    for (final b in buildings) {
      if (b['id'] == buildingId) return floorsOf(b);
    }
    return buildings.fold<int>(1, (most, b) {
      final floors = floorsOf(b);
      return floors > most ? floors : most;
    });
  }

  /// The connections with an end in university [placeId] or building
  /// [buildingId] (the building wins; neither: all), saved ones only.
  List<Map<String, dynamic>> connectionsInScope({
    String? placeId,
    String? buildingId,
  }) {
    final buildingOf = {
      for (final p in anchorPoints) p['id'] as String: p['building_id'],
    };
    final placeBuildings = {
      for (final b in buildings)
        if (b['place_id'] == placeId) b['id'],
    };
    bool inside(String? pointId) {
      final building = buildingOf[pointId];
      if (buildingId != null) return building == buildingId;
      return placeId == null || placeBuildings.contains(building);
    }

    return connections.where((c) {
      if (c['pending'] == true) return false;
      return inside(c['anchor_point_a_id'] as String?) ||
          inside(c['anchor_point_b_id'] as String?);
    }).toList();
  }
}

/// What a delete takes with it: the buildings and points themselves, and
/// how many photos and connections.
typedef Cascade = ({
  List<Map<String, dynamic>> buildings,
  List<Map<String, dynamic>> anchors,
  int photos,
  int connections,
});

/// Universities or buildings whose name contains [query] (already lower
/// case), sorted by name; with [placeId], only that university's.
List<Map<String, dynamic>> rowsByName(
  List<Map<String, dynamic>> rows,
  String query, {
  String? placeId,
}) {
  String name(Map<String, dynamic> row) => row['name'] as String? ?? '';
  return rows
      .where(
        (r) =>
            (placeId == null || r['place_id'] == placeId) &&
            name(r).toLowerCase().contains(query),
      )
      .toList()
    ..sort((a, b) => name(a).compareTo(name(b)));
}

/// What system back does on the admin home, in order: a move, a selected
/// point, Connect mode, the map's filters and level, the Anchor points
/// filters; then the tab before, a drill-down's filter, the map, and only
/// then "press again to exit".
enum AdminBack {
  cancelMove,
  releaseSelection,
  leaveConnect,
  clearPointFilters,
  levelUp,
  previousTab,
  clearDrillDown,
  toMap,
  exitGuard,
}

AdminBack adminBack({
  required bool onMap,
  required bool onPoints,
  required bool moving,
  required bool pointSelected,
  required bool connecting,
  required bool pointFilters,
  required bool scoped,
  required bool history,
  required bool drillDown,
}) {
  if (onMap && moving) return AdminBack.cancelMove;
  if (onMap && pointSelected) return AdminBack.releaseSelection;
  if (onMap && connecting) return AdminBack.leaveConnect;
  if ((onMap || onPoints) && pointFilters) return AdminBack.clearPointFilters;
  if (onMap && scoped) return AdminBack.levelUp;
  if (history) return AdminBack.previousTab;
  if (drillDown) return AdminBack.clearDrillDown;
  if (!onMap) return AdminBack.toMap;
  return AdminBack.exitGuard;
}

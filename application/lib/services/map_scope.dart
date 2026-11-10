/// Where the admin map is (everything, a university or a building) and its
/// search over all three. Pure, so it's unit-tested.
library;

import 'destination_matcher.dart' show normalizeForMatch;

/// The admin map's level: everything, one university, or one building of it.
class MapScope {
  final String? placeId;
  final String? buildingId;

  const MapScope({this.placeId, this.buildingId});

  static const all = MapScope();

  bool get isAll => placeId == null && buildingId == null;

  /// One level up: a building's university, then everything.
  MapScope get up =>
      buildingId != null ? MapScope(placeId: placeId) : MapScope.all;

  /// The building [building] (a `buildings` row) is the scope.
  factory MapScope.building(Map<String, dynamic> building) => MapScope(
    placeId: building['place_id'] as String?,
    buildingId: building['id'] as String?,
  );

  /// This scope, or the nearest level above it that still exists.
  MapScope existingIn({
    required Set<String> placeIds,
    required Set<String> buildingIds,
  }) {
    if (buildingId != null && !buildingIds.contains(buildingId)) {
      return MapScope(
        placeId: placeId,
      ).existingIn(placeIds: placeIds, buildingIds: buildingIds);
    }
    if (placeId != null && !placeIds.contains(placeId)) return MapScope.all;
    return this;
  }

  @override
  bool operator ==(Object other) =>
      other is MapScope &&
      other.placeId == placeId &&
      other.buildingId == buildingId;

  @override
  int get hashCode => Object.hash(placeId, buildingId);
}

enum MapSearchKind { place, building, point }

/// One search result: a `places`, `buildings` or `anchor_points` row.
class MapSearchResult {
  final MapSearchKind kind;
  final Map<String, dynamic> item;

  /// The name shown, and a line saying where it is.
  final String title;
  final String subtitle;

  const MapSearchResult(this.kind, this.item, this.title, this.subtitle);
}

/// Universities, buildings and points matching [query]: every word must
/// appear (accents and case ignored) in the name, code or, for a point, its
/// building's name. Whole-name matches come first, then names starting
/// with the query, then the rest; universities before buildings before
/// points when equal.
List<MapSearchResult> searchMap(
  String query, {
  required List<Map<String, dynamic>> places,
  required List<Map<String, dynamic>> buildings,
  required List<Map<String, dynamic>> points,
  required String Function(Map<String, dynamic> point) pointName,
  int limit = 8,
}) {
  final q = normalizeForMatch(query);
  if (q.isEmpty) return const [];
  final words = q.split(' ');
  final placesById = {for (final p in places) p['id']: p};
  final buildingsById = {for (final b in buildings) b['id']: b};

  final scored = <(int, MapSearchResult)>[];
  void consider(
    MapSearchKind kind,
    Map<String, dynamic> item,
    String title,
    String subtitle,
    List<String?> alsoMatched,
  ) {
    final name = normalizeForMatch(title);
    final haystack = normalizeForMatch(
      [title, ...alsoMatched.whereType<String>()].join(' '),
    );
    if (!words.every(haystack.contains)) return;
    final rank = name == q
        ? 0
        : name.startsWith(q)
        ? 1
        : 2;
    scored.add((
      rank * 3 + kind.index,
      MapSearchResult(kind, item, title, subtitle),
    ));
  }

  for (final place in places) {
    final name = place['name'] as String? ?? '';
    consider(MapSearchKind.place, place, name, place['code'] as String? ?? '', [
      place['code'] as String?,
    ]);
  }
  for (final building in buildings) {
    final name = building['name'] as String? ?? '';
    final place = placesById[building['place_id']];
    consider(
      MapSearchKind.building,
      building,
      name,
      place?['name'] as String? ?? '',
      [building['code'] as String?],
    );
  }
  for (final point in points) {
    final building = buildingsById[point['building_id']];
    final place = building == null ? null : placesById[building['place_id']];
    final buildingName = building?['name'] as String?;
    consider(
      MapSearchKind.point,
      point,
      pointName(point),
      [buildingName, place?['name'] as String?].whereType<String>().join(' · '),
      [buildingName],
    );
  }
  scored.sort((a, b) {
    final byRank = a.$1.compareTo(b.$1);
    return byRank != 0 ? byRank : a.$2.title.compareTo(b.$2.title);
  });
  return [for (final s in scored.take(limit)) s.$2];
}

/// The points of [scope]: a building's, a university's, or all of them.
List<Map<String, dynamic>> pointsInScope(
  MapScope scope, {
  required List<Map<String, dynamic>> buildings,
  required List<Map<String, dynamic>> points,
}) {
  if (scope.buildingId case final id?) {
    return [
      for (final p in points)
        if (p['building_id'] == id) p,
    ];
  }
  if (scope.placeId case final id?) {
    final buildingIds = {
      for (final b in buildings)
        if (b['place_id'] == id) b['id'],
    };
    return [
      for (final p in points)
        if (buildingIds.contains(p['building_id'])) p,
    ];
  }
  return points;
}

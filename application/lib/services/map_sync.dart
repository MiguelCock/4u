import 'dart:convert';

import 'api_service.dart';

/// Many admins editing the map at once (A5): what backend-map-management's
/// `GET /changes` returns is merged into the admin screen's lists, and a save
/// sends the values it was based on, so another admin's edit is never silently
/// overwritten. Pure, so it's tested without a server.

/// The admin screen's five lists, by the table names `/changes` uses.
class MapLists {
  const MapLists({
    required this.places,
    required this.buildings,
    required this.anchorPoints,
    required this.photos,
    required this.connections,
  });

  final List<Map<String, dynamic>> places;
  final List<Map<String, dynamic>> buildings;
  final List<Map<String, dynamic>> anchorPoints;
  final List<Map<String, dynamic>> photos;
  final List<Map<String, dynamic>> connections;

  static const tables = [
    'places',
    'buildings',
    'anchor_points',
    'anchor_point_photos',
    'anchor_point_connections',
  ];

  List<Map<String, dynamic>> byTable(String table) => switch (table) {
    'places' => places,
    'buildings' => buildings,
    'anchor_points' => anchorPoints,
    'anchor_point_photos' => photos,
    _ => connections,
  };
}

class MergeResult {
  const MergeResult(this.lists, this.newChanges);

  final MapLists lists;

  /// Rows added, changed or removed that weren't already known: what another
  /// admin did. A row already merged at the same `updated_at` doesn't count,
  /// so an admin's own edit, synced right after saving, isn't announced.
  final int newChanges;
}

/// Merges one `/changes` answer: changed rows replace theirs by id, new ones
/// are added, deleted ids are removed. Merging the same answer twice is
/// harmless, which `/changes` relies on (its answers overlap a little).
MergeResult applyChanges(MapLists lists, Map<String, dynamic> changes) {
  var newChanges = 0;
  final deleted = (changes['deleted'] as Map?) ?? const {};
  final merged = <String, List<Map<String, dynamic>>>{};
  for (final table in MapLists.tables) {
    final rows = [...lists.byTable(table)];
    final index = {
      for (var i = 0; i < rows.length; i++) rows[i]['id'] as String: i,
    };
    for (final change in (changes[table] as List? ?? const [])) {
      final row = Map<String, dynamic>.from(change as Map);
      final at = index[row['id']];
      if (at == null) {
        index[row['id'] as String] = rows.length;
        rows.add(row);
        newChanges++;
      } else {
        if (rows[at]['updated_at'] != row['updated_at']) newChanges++;
        rows[at] = row;
      }
    }
    final gone = {...((deleted[table] as List?) ?? const []).cast<String>()};
    final before = rows.length;
    rows.removeWhere((row) => gone.contains(row['id']));
    newChanges += before - rows.length;
    merged[table] = rows;
  }
  return MergeResult(
    MapLists(
      places: merged['places']!,
      buildings: merged['buildings']!,
      anchorPoints: merged['anchor_points']!,
      photos: merged['anchor_point_photos']!,
      connections: merged['anchor_point_connections']!,
    ),
    newChanges,
  );
}

/// What the admin screen's 30 s refresh does.
enum SyncTick {
  /// Another screen or a dialog covers it: wait. Whatever this admin changes
  /// there would otherwise be announced as another admin's change.
  skip,

  /// Just uncovered: merge without a notice, since it holds this admin's own
  /// changes. Other admins' changes from that time are merged too, silently.
  silent,

  /// Merge, and say how many changes came from other admins.
  announce,
}

SyncTick syncTickAction({required bool covered, required bool wasCovered}) {
  if (covered) return SyncTick.skip;
  return wasCovered ? SyncTick.silent : SyncTick.announce;
}

/// The fields of [edited] that differ from [original]: a save sends only
/// these, so another admin's edit to a different field isn't touched.
Map<String, dynamic> changedFields(
  Map<String, dynamic> original,
  Map<String, dynamic> edited,
) => {
  for (final entry in edited.entries)
    if (!_same(original[entry.key], entry.value)) entry.key: entry.value,
};

/// What each changed field held when the admin started editing: the backend
/// only applies the save where it still does (`expected`).
Map<String, dynamic> expectedFor(
  Map<String, dynamic> original,
  Map<String, dynamic> changes,
) => {for (final key in changes.keys) key: original[key]};

bool _same(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is Map || b is Map) return jsonEncode(a ?? {}) == jsonEncode(b ?? {});
  return a == b;
}

/// Another admin changed the point since this one opened it: the 409 from
/// `PATCH /anchor-points/{id}` when `expected` no longer held.
class MapConflict {
  const MapConflict(this.fields, this.current);

  final List<String> fields;
  final Map<String, dynamic> current;

  static MapConflict? of(ApiException error) {
    if (error.statusCode != 409) return null;
    try {
      final detail = (jsonDecode(error.body) as Map)['detail'];
      if (detail is! Map || detail['current'] is! Map) return null;
      return MapConflict(
        (detail['fields'] as List? ?? const []).cast<String>(),
        Map<String, dynamic>.from(detail['current'] as Map),
      );
    } catch (_) {
      return null;
    }
  }
}

import 'package:latlong2/latlong.dart';

import 'destinations.dart';
import 'geo_utils.dart';

/// Checks that keep admins from the mapping mistakes found in the Icesi
/// data (2026-11-03): connections of 36-76 m, points saved on top of each
/// other, named places saved as hallways (hidden from users) and verified
/// points nobody can walk to. The backend refuses the worst of these too
/// (`backend-map-management`'s `MAX_CONNECTION_METERS` and
/// `DUPLICATE_POINT_METERS`); these let the app warn before sending.

/// Longest connection the backend accepts.
const double kMaxConnectionMeters = 30;

/// Connections longer than this get a warning: points are captured every
/// 6-8 m.
const double kConnectionWarnMeters = 15;

/// Another point on the same floor this close asks for confirmation.
const double kNearbyPointMeters = 3;

/// Closer than this the backend refuses unless the admin confirmed.
const double kDuplicatePointMeters = 1;

/// "Use my location" is offered only with a GPS fix at least this good.
const double kMaxCaptureGpsAccuracyMeters = 8;

/// Elevator, stairwell and ramp: where a connection may change floor.
/// Mirrors `VERTICAL_LOCATION_TYPE_IDS` in `backend-map-management`.
const Set<int> kVerticalLocationTypes = {3, 4, 11};

LatLng? anchorLatLng(Map<String, dynamic> anchor) {
  final lat = (anchor['latitude'] as num?)?.toDouble();
  final lng = (anchor['longitude'] as num?)?.toDouble();
  return lat == null || lng == null ? null : LatLng(lat, lng);
}

/// The point nearest [position] in the same building and floor, if one is
/// within [kNearbyPointMeters].
({Map<String, dynamic> anchor, double meters})? nearbyPoint(
  Iterable<Map<String, dynamic>> anchors, {
  required String? buildingId,
  required int floor,
  required LatLng position,
  String? excludeId,
}) {
  ({Map<String, dynamic> anchor, double meters})? nearest;
  for (final anchor in anchors) {
    if (anchor['id'] == excludeId ||
        anchor['building_id'] != buildingId ||
        ((anchor['floor'] as int?) ?? 0) != floor) {
      continue;
    }
    final other = anchorLatLng(anchor);
    if (other == null) continue;
    final meters = haversineMeters(position, other);
    if (meters <= kNearbyPointMeters &&
        (nearest == null || meters < nearest.meters)) {
      nearest = (anchor: anchor, meters: meters);
    }
  }
  return nearest;
}

enum ConnectionProblem { tooLong, floorChange }

/// Why connecting [a] and [b] would be refused, or null if it's fine.
ConnectionProblem? connectionProblem(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
) {
  final distance = anchorDistance(a, b);
  if (distance != null && distance > kMaxConnectionMeters) {
    return ConnectionProblem.tooLong;
  }
  if (((a['floor'] as int?) ?? 0) != ((b['floor'] as int?) ?? 0) &&
      !kVerticalLocationTypes.contains(a['location_type_id']) &&
      !kVerticalLocationTypes.contains(b['location_type_id'])) {
    return ConnectionProblem.floorChange;
  }
  return null;
}

/// Straight-line distance between two anchor points, null if either has
/// no position.
double? anchorDistance(Map<String, dynamic> a, Map<String, dynamic> b) {
  final pa = anchorLatLng(a);
  final pb = anchorLatLng(b);
  return pa == null || pb == null ? null : haversineMeters(pa, pb);
}

/// A name typed on an in-between type (hallway…): users can't pick it as a
/// destination, which is usually not what the admin meant.
bool isNamedInBetweenPoint(int? locationTypeId, String description) =>
    description.trim().isNotEmpty && !isDestinationType(locationTypeId);

/// Verified points with no connection: users can neither reach them nor
/// start from them.
List<Map<String, dynamic>> verifiedUnconnectedPoints(
  Iterable<Map<String, dynamic>> anchors,
  Iterable<Map<String, dynamic>> connections,
) {
  final connected = connectedAnchorIds(connections);
  return anchors
      .where((a) => a['status'] == 'verified' && !connected.contains(a['id']))
      .toList();
}

/// Named points of an in-between type, which never appear in the users'
/// destination list. Some are deliberate ("Pasillo hacia salas 202"), so
/// this is a list to review, not an error.
List<Map<String, dynamic>> namedHiddenPoints(
  Iterable<Map<String, dynamic>> anchors,
) => anchors
    .where(
      (a) => isNamedInBetweenPoint(
        a['location_type_id'] as int?,
        a['location_description'] as String? ?? '',
      ),
    )
    .toList();

/// Connections that change floor with no stairs, elevator or ramp at either
/// end, made before that rule. Routes don't use them.
List<Map<String, dynamic>> floorChangeConnections(
  Iterable<Map<String, dynamic>> anchors,
  Iterable<Map<String, dynamic>> connections,
) {
  final byId = {for (final a in anchors) a['id']: a};
  return connections.where((c) {
    final a = byId[c['anchor_point_a_id']];
    final b = byId[c['anchor_point_b_id']];
    if (a == null || b == null) return false;
    return ((a['floor'] as int?) ?? 0) != ((b['floor'] as int?) ?? 0) &&
        !kVerticalLocationTypes.contains(a['location_type_id']) &&
        !kVerticalLocationTypes.contains(b['location_type_id']);
  }).toList();
}

/// Connections longer than [kMaxConnectionMeters], made before the limit.
List<Map<String, dynamic>> longConnections(
  Iterable<Map<String, dynamic>> anchors,
  Iterable<Map<String, dynamic>> connections,
) {
  final byId = {for (final a in anchors) a['id']: a};
  return connections.where((c) {
    final a = byId[c['anchor_point_a_id']];
    final b = byId[c['anchor_point_b_id']];
    if (a == null || b == null) return false;
    final distance = anchorDistance(a, b);
    return distance != null && distance > kMaxConnectionMeters;
  }).toList();
}

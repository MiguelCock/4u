import 'package:latlong2/latlong.dart';

import 'capture_checks.dart' show kVerticalLocationTypes;
import 'destinations.dart';
import 'floor_view.dart';
import 'geo_utils.dart';
import 'route_points.dart';

/// Where guidance stops: a corner, a named place, a stairwell, elevator or
/// ramp, a floor change, or the destination. Unnamed in-between points
/// (hallways...) are never spoken, so guidance is just directions.
class Waypoint {
  final LatLng point;
  final String? name;

  /// 0-based, like `anchor_points.floor`.
  final int floor;

  /// Stairwell, elevator or ramp (kVerticalLocationTypes): warned about
  /// before reaching it.
  final int? hazardType;

  /// The admins' warnings ("three steps down") on the connections of the
  /// leg that ends here, spoken when that leg starts.
  final List<String> legNotes;

  const Waypoint({
    required this.point,
    this.name,
    this.floor = 0,
    this.hazardType,
    this.legNotes = const [],
  });
}

/// A route ready for guidance: its line, and the stops along it.
class TripPlan {
  const TripPlan({
    required this.points,
    required this.floors,
    required this.waypoints,
    required this.cornerCount,
    this.startPoint,
    this.startFloor,
    this.startHazard,
    this.startTypeId,
  });

  /// Every point found, start included, for the line on the map.
  final List<LatLng> points;
  final List<int> floors;

  /// Where guidance stops, start excluded (there's nothing to approach at
  /// the point you're standing at).
  final List<Waypoint> waypoints;

  /// The corners alone (not named places), for the test-walk checkpoints:
  /// the same rule backend-positioning/scripts/replay.py scores a walk by.
  final int cornerCount;

  /// The start, when it was found.
  final LatLng? startPoint;
  final int? startFloor;
  final int? startHazard;
  final int? startTypeId;
}

/// The route [ids] (start, waypoints, end) with their loaded [route]
/// points, as stops for guidance. A missing point is skipped; a
/// connection's note goes to the leg that ends at the next point found.
TripPlan buildTripPlan(List<String> ids, RoutePoints route) {
  final anchors = route.anchors;
  String? noteBetween(int i) {
    final a = ids[i];
    final b = ids[i + 1];
    for (final c in route.connections[i]) {
      final ends = {c['anchor_point_a_id'], c['anchor_point_b_id']};
      if (ends.contains(a) && ends.contains(b)) {
        final note = (c['notes'] as String? ?? '').trim();
        return note.isEmpty ? null : note;
      }
    }
    return null;
  }

  final points = <LatLng>[];
  final names = <String?>[];
  final hazards = <int?>[];
  final floors = <int>[];
  // The note of the connection arriving at each point found.
  final notes = <String?>[];
  String? pendingNote;
  LatLng? startPoint;
  for (var i = 0; i < anchors.length; i++) {
    final anchor = anchors[i];
    final point = anchor == null ? null : anchorPosition(anchor);
    if (i > 0) pendingNote ??= noteBetween(i - 1);
    if (anchor == null || point == null) continue;
    notes.add(pendingNote);
    pendingNote = null;
    final type = anchor['location_type_id'] as int?;
    hazards.add(kVerticalLocationTypes.contains(type) ? type : null);
    floors.add(pointFloor(anchor));
    points.add(point);
    if (i == 0) startPoint = point;
    final description = (anchor['location_description'] as String? ?? '')
        .trim();
    // The final point is always named when spoken (falling back to "your
    // destination"); in-between ones only if they're a real
    // destination-type place.
    final named =
        i > 0 &&
        description.isNotEmpty &&
        (i == ids.length - 1 || isDestinationAnchor(anchor));
    names.add(named ? description : null);
  }
  // Guidance stops at corners (and named places), not at every anchor along
  // a straight - see routeCorners. Stairs, elevators and ramps stay too:
  // they're warned about. So do both ends of any floor change, wherever
  // guidance has to wait for one.
  final corners = routeCorners(
    points,
    keep: {
      for (var i = 0; i < names.length; i++)
        if (names[i] != null ||
            hazards[i] != null ||
            (i > 0 && floors[i - 1] != floors[i]) ||
            (i + 1 < floors.length && floors[i + 1] != floors[i]))
          i,
    },
  );
  final waypoints = <Waypoint>[];
  for (var k = 0; k < corners.length; k++) {
    final i = corners[k];
    if (i == 0 && startPoint != null) continue;
    final from = k == 0 ? 0 : corners[k - 1] + 1;
    waypoints.add(
      Waypoint(
        point: points[i],
        name: names[i],
        floor: floors[i],
        hazardType: hazards[i],
        legNotes: [
          for (var j = from; j <= i; j++)
            if (notes[j] != null) notes[j]!,
        ],
      ),
    );
  }
  return TripPlan(
    points: points,
    floors: floors,
    waypoints: waypoints,
    cornerCount: routeCorners(points).length,
    startPoint: startPoint,
    startFloor: floors.isEmpty ? null : floors.first,
    startHazard: hazards.isEmpty ? null : hazards.first,
    startTypeId: anchors.isEmpty
        ? null
        : anchors.first?['location_type_id'] as int?,
  );
}

/// Where guidance resumes along [waypoints] from [here]: the nearest stop,
/// or the one after it when the user is already past it along the next
/// straight (corners can be 40 m apart; don't send them back). Never
/// across a floor change.
int resumeWaypointIndex(LatLng here, List<Waypoint> waypoints) {
  var nearest = 0;
  var nearestDistance = double.infinity;
  for (var i = 0; i < waypoints.length; i++) {
    final distance = haversineMeters(here, waypoints[i].point);
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearest = i;
    }
  }
  if (nearest + 1 < waypoints.length &&
      waypoints[nearest + 1].floor == waypoints[nearest].floor &&
      projectOntoSegment(
            here,
            waypoints[nearest].point,
            waypoints[nearest + 1].point,
          ).along >
          0) {
    nearest++;
  }
  return nearest;
}

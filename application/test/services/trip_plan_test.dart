import 'package:eyes4u/services/route_points.dart';
import 'package:eyes4u/services/trip_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

Map<String, dynamic> _point(
  String id,
  double lat,
  double lng, {
  int type = 2, // hallway
  String name = '',
  int floor = 0,
}) => {
  'id': id,
  'location_type_id': type,
  'location_description': name,
  'floor': floor,
  'latitude': lat,
  'longitude': lng,
};

Map<String, dynamic> _link(String a, String b, {String? notes}) => {
  'anchor_point_a_id': a,
  'anchor_point_b_id': b,
  'notes': notes,
};

void main() {
  group('buildTripPlan', () {
    // North 33 m (through a straight point) to a corner, then east 33 m.
    final ids = ['s', 'mid', 'c', 'end'];
    final anchors = [
      _point('s', 6.2000, -75.5800, type: 1, name: 'Entrada'),
      _point('mid', 6.20015, -75.5800),
      _point('c', 6.2003, -75.5800),
      _point('end', 6.2003, -75.5797, type: 23, name: 'Biblioteca'),
    ];
    final links = [
      [_link('s', 'mid')],
      [_link('mid', 'c', notes: 'Tres escalones')],
      [_link('c', 'end')],
    ];

    test('stops at the corner and the destination, not on the straight', () {
      final plan = buildTripPlan(ids, RoutePoints(anchors, links));
      expect(plan.points, hasLength(4));
      expect(plan.startPoint, const LatLng(6.2, -75.58));
      expect(plan.waypoints.map((w) => w.point), [
        const LatLng(6.2003, -75.58),
        const LatLng(6.2003, -75.5797),
      ]);
      expect(plan.waypoints.last.name, 'Biblioteca');
      expect(plan.waypoints.first.name, isNull); // a hallway isn't spoken
      expect(plan.startTypeId, 1);
    });

    test('a leg carries the notes of the connections it covers', () {
      final plan = buildTripPlan(ids, RoutePoints(anchors, links));
      expect(plan.waypoints.first.legNotes, ['Tres escalones']);
      expect(plan.waypoints.last.legNotes, isEmpty);
    });

    test('stairs and both ends of a floor change are kept', () {
      final plan = buildTripPlan(
        ['s', 'stairs', 'up', 'end'],
        RoutePoints([
          _point('s', 6.2000, -75.5800),
          _point('stairs', 6.20015, -75.5800, type: 4),
          _point('up', 6.2002, -75.5800, floor: 1),
          _point('end', 6.2003, -75.5800, floor: 1, type: 23, name: 'Aula'),
        ], List.filled(3, const [])),
      );
      expect(plan.waypoints.map((w) => w.floor), [0, 1, 1]);
      expect(plan.waypoints.first.hazardType, 4);
      expect(plan.floors, [0, 0, 1, 1]);
    });

    test('a missing point is skipped, and the start may be missing', () {
      final plan = buildTripPlan(
        ids,
        RoutePoints([null, anchors[1], anchors[2], anchors[3]], links),
      );
      expect(plan.startPoint, isNull);
      expect(plan.points, hasLength(3));
      // Without a start, the first point found is a stop too.
      expect(plan.waypoints.first.point, const LatLng(6.20015, -75.58));
    });
  });

  group('resumeWaypointIndex', () {
    final stops = [
      const Waypoint(point: LatLng(6.2003, -75.5800)),
      const Waypoint(point: LatLng(6.2003, -75.5797)),
      const Waypoint(point: LatLng(6.2006, -75.5797), floor: 1),
    ];

    test('the nearest stop', () {
      expect(resumeWaypointIndex(const LatLng(6.2002, -75.5800), stops), 0);
    });

    test('past the nearest along the next straight: the one after', () {
      expect(resumeWaypointIndex(const LatLng(6.2003, -75.57995), stops), 1);
    });

    test('never across a floor change', () {
      expect(resumeWaypointIndex(const LatLng(6.20035, -75.5797), stops), 1);
    });
  });
}

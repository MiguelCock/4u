import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:eyes4u/services/capture_checks.dart';

/// A point [north] metres north of a fixed origin (0.00009 deg is ~10 m).
Map<String, dynamic> point(
  String id,
  double north, {
  int floor = 0,
  int type = 10,
  String building = 'b1',
  String status = 'verified',
  String? name,
}) => {
  'id': id,
  'building_id': building,
  'floor': floor,
  'location_type_id': type,
  'latitude': 3.34 + north / 111195,
  'longitude': -76.53,
  'status': status,
  'location_description': name,
};

void main() {
  const origin = LatLng(3.34, -76.53);

  group('nearbyPoint', () {
    test('finds a point 2 m away on the same floor', () {
      final hit = nearbyPoint(
        [point('a', 2)],
        buildingId: 'b1',
        floor: 0,
        position: origin,
      );
      expect(hit?.anchor['id'], 'a');
      expect(hit!.meters, closeTo(2, 0.1));
    });

    test('ignores other floors, other buildings, far points and itself', () {
      final hit = nearbyPoint(
        [
          point('up', 0.5, floor: 1),
          point('other', 0.5, building: 'b2'),
          point('far', 5),
          point('self', 0),
        ],
        buildingId: 'b1',
        floor: 0,
        position: origin,
        excludeId: 'self',
      );
      expect(hit, isNull);
    });
  });

  group('connectionProblem', () {
    test('a 6 m hallway connection is fine', () {
      expect(connectionProblem(point('a', 0), point('b', 6)), isNull);
    });

    test('over 30 m is too long', () {
      expect(
        connectionProblem(point('a', 0), point('b', 50)),
        ConnectionProblem.tooLong,
      );
    });

    test('a floor change needs stairs, an elevator or a ramp', () {
      expect(
        connectionProblem(point('a', 0), point('b', 3, floor: 1)),
        ConnectionProblem.floorChange,
      );
      expect(
        connectionProblem(point('a', 0), point('b', 3, floor: 1, type: 4)),
        isNull,
      );
    });
  });

  test('isNamedInBetweenPoint', () {
    expect(isNamedInBetweenPoint(10, 'Wonka'), isTrue);
    expect(isNamedInBetweenPoint(10, '  '), isFalse);
    expect(isNamedInBetweenPoint(7, 'Baño mujeres'), isFalse);
  });

  test('data health lists', () {
    final anchors = [
      point('a', 0),
      point('b', 6),
      point('loose', 100),
      point('pending', 200, status: 'pending'),
      point('far', 300, name: 'Wonka'),
    ];
    final connections = [
      {'anchor_point_a_id': 'a', 'anchor_point_b_id': 'b'},
      {'anchor_point_a_id': 'b', 'anchor_point_b_id': 'far'},
    ];
    expect(
      verifiedUnconnectedPoints(anchors, connections).map((a) => a['id']),
      ['loose'],
    );
    expect(namedHiddenPoints(anchors).map((a) => a['id']), ['far']);
    expect(longConnections(anchors, connections), [connections[1]]);
  });
}

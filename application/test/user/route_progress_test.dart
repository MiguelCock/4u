import 'package:eyes4u/services/trip_plan.dart';
import 'package:eyes4u/user/route_progress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// A point [n] meters north and [e] meters east of the route's start.
LatLng _at(double n, [double e = 0]) =>
    LatLng(6.2 + n / 111195, -75.58 + e / 110545);

final _start = _at(0);
final _t0 = DateTime(2026, 11, 15, 10);

/// A route from [_start] through [stops], [startFloor] being the start's.
RouteProgress _route(
  List<Waypoint> stops, {
  int startFloor = 0,
  int? startHazard,
}) => RouteProgress()
  ..load(
    TripPlan(
      points: [_start, for (final w in stops) w.point],
      floors: [startFloor, for (final w in stops) w.floor],
      waypoints: stops,
      cornerCount: 0,
      startPoint: _start,
      startFloor: startFloor,
      startHazard: startHazard,
    ),
  );

/// An L: 33 m north to a right turn, then 33 m east to the end.
RouteProgress _l() => _route([
  Waypoint(point: _at(33)),
  Waypoint(point: _at(33, 33), name: 'Biblioteca'),
]);

Reach? _reach(
  RouteProgress route,
  LatLng here, {
  LatLng? raw,
  bool rawToo = true,
  double? heading,
}) => route.reach(
  here: here,
  raw: rawToo ? (raw ?? here) : null,
  gpsAccuracy: 5,
  heading: heading,
  now: _t0,
);

void main() {
  group('corners', () {
    test('reached within 3 m, and the next leg is given', () {
      final route = _l();
      expect(_reach(route, _at(25)), isNull);
      final reach = _reach(route, _at(31)) as ReachedCorner;
      expect(reach.index, 0);
      expect(reach.skipped, 0);
      expect(reach.previous, _start);
      expect(reach.to.name, 'Biblioteca');
      expect(route.next, 1);
      expect(route.segmentStart, _at(33));
    });

    test('reached along its straight, though a few meters to the side', () {
      final route = _l();
      // 2 m short along the leg, 5 m to the side: 5.4 m from the corner.
      expect(_reach(route, _at(31, 5)), isA<ReachedCorner>());
    });

    test('an early turn counts only with a trusted heading', () {
      final here = _at(27); // 6 m before: near, not reached
      expect(_reach(_l(), here), isNull);
      expect(_reach(_l(), here, heading: 90), isA<ReachedCorner>());
      // Still facing along the leg: not turned yet.
      expect(_reach(_l(), here, heading: 0), isNull);
    });
  });

  group('skipping ahead', () {
    // Two corners, then the end: S → 33 N → 33 E → 33 N.
    RouteProgress zigzag() => _route([
      Waypoint(point: _at(33)),
      Waypoint(point: _at(33, 33)),
      Waypoint(point: _at(66, 33)),
    ]);

    test('to a later corner when raw GPS agrees', () {
      final route = zigzag();
      final reach = _reach(route, _at(33, 33)) as ReachedCorner;
      expect(reach.index, 1);
      expect(reach.skipped, 1);
      expect(route.next, 2);
    });

    test('not on the corrected position alone', () {
      expect(_reach(zigzag(), _at(33, 33), rawToo: false), isNull);
      // Raw GPS still at the corner before.
      expect(_reach(zigzag(), _at(33, 33), raw: _at(33)), isNull);
    });
  });

  group('arrival', () {
    test('on two ticks in a row', () {
      final route = _l();
      _reach(route, _at(33));
      expect(_reach(route, _at(33, 33)), isNull);
      final end = _reach(route, _at(33, 33));
      expect(end, isA<ReachedEnd>());
      expect(end!.index, 1);
    });

    test('a tick away from it starts the count again', () {
      final route = _l();
      _reach(route, _at(33));
      _reach(route, _at(33, 33));
      _reach(route, _at(33, 15));
      expect(_reach(route, _at(33, 33)), isNull);
      expect(_reach(route, _at(33, 33)), isA<ReachedEnd>());
    });

    test('not while raw GPS is far from it', () {
      final route = _l();
      _reach(route, _at(33));
      for (var i = 0; i < 3; i++) {
        expect(_reach(route, _at(33, 33), raw: _at(33, 8)), isNull);
      }
    });

    test('straight from the start, skipping the corner', () {
      final route = _l();
      _reach(route, _at(33, 33));
      final end = _reach(route, _at(33, 33))!;
      expect(end, isA<ReachedEnd>());
      expect(end.skipped, 1);
    });
  });

  group('floors', () {
    // Stairs 33 m north, the same spot upstairs, the end 33 m east upstairs.
    RouteProgress upstairs({int floors = 1}) => _route([
      Waypoint(point: _at(33), hazardType: 4),
      Waypoint(point: _at(33), floor: floors, hazardType: 4),
      Waypoint(point: _at(33, 33), floor: floors),
    ]);

    test('a stop on another floor is never reached', () {
      final route = upstairs();
      _reach(route, _at(33));
      for (var i = 0; i < 3; i++) {
        expect(_reach(route, _at(33, 33)), isNull);
      }
      expect(route.next, 1);
    });

    test('the foot of the stairs begins the wait', () {
      final route = upstairs();
      final reach = _reach(route, _at(33)) as ReachedFloorChange;
      expect(reach.wait.fromFloor, 0);
      expect(reach.wait.toFloor, 1);
      expect(reach.wait.hazardTypes, {4});
      expect(route.waitingForFloor, isTrue);
      expect(route.floorChange, (lastIndex: 1, floor: 1));
    });

    test('heard by the barometer: on from the far end', () {
      final route = upstairs();
      for (var s = 0; s < 5; s++) {
        route.detector.add(1000, _t0.subtract(Duration(seconds: 5 - s)));
      }
      _reach(route, _at(33));
      for (var s = 0; s <= 6; s++) {
        route.detector.add(999.6, _t0.add(Duration(seconds: s)));
      }
      final done = route.checkFloorChange(
        barometerSeen: true,
        now: _t0.add(const Duration(seconds: 6)),
      )!;
      expect(done.detected, isTrue);
      expect(done.floor, 1);
      expect(done.arrived, isFalse);
      expect(done.deltaHpa, closeTo(-0.4, 0.01));
      expect(route.floor, 1);
      expect(route.next, 2);
      expect(route.needsStartCue, isTrue);
      expect(route.waitingForFloor, isFalse);
    });

    test('with a barometer that hears nothing: given up after 3 min', () {
      final route = upstairs();
      _reach(route, _at(33));
      DateTime after(Duration d) => _t0.add(d);
      expect(
        route.checkFloorChange(
          barometerSeen: true,
          now: after(const Duration(minutes: 2, seconds: 59)),
        ),
        isNull,
      );
      final done = route.checkFloorChange(
        barometerSeen: true,
        now: after(const Duration(minutes: 3)),
      )!;
      expect(done.detected, isFalse);
      expect(done.waited, const Duration(minutes: 3));
    });

    test('with no barometer: 60 s per floor', () {
      final route = upstairs(floors: 2);
      _reach(route, _at(33));
      expect(
        route.checkFloorChange(
          barometerSeen: false,
          now: _t0.add(const Duration(seconds: 119)),
        ),
        isNull,
      );
      expect(
        route
            .checkFloorChange(
              barometerSeen: false,
              now: _t0.add(const Duration(seconds: 120)),
            )!
            .floor,
        2,
      );
    });

    test('a floor change ending at the destination arrives', () {
      final route = _route([
        Waypoint(point: _at(33), hazardType: 3),
        Waypoint(point: _at(33), floor: 1, name: 'Biblioteca'),
      ]);
      _reach(route, _at(33));
      final done = route.checkFloorChange(
        barometerSeen: false,
        now: _t0.add(const Duration(minutes: 1)),
      )!;
      expect(done.arrived, isTrue);
      expect(route.needsStartCue, isFalse);
    });

    test('a route starting at the foot of the stairs: once', () {
      final route = _route([
        Waypoint(point: _start, floor: 1, hazardType: 4),
        Waypoint(point: _at(33), floor: 1),
      ], startHazard: 4);
      final wait = route.checkStartFloor(_t0)!;
      expect(wait.toFloor, 1);
      expect(wait.hazardTypes, {4});
      expect(route.checkStartFloor(_t0), isNull);
    });

    test('resuming takes the nearest stop\'s floor', () {
      final route = upstairs()..resumeNear(_at(33, 30));
      expect(route.next, 2);
      expect(route.floor, 1);
      expect(route.checkStartFloor(_t0), isNull);
    });
  });

  group('warning before a corner', () {
    test('the turn, once, about 8 m before', () {
      final route = _l();
      expect(route.warnAhead(_at(20), heading: null), isNull);
      final warning = route.warnAhead(_at(26), heading: null)!;
      expect(warning.turn, greaterThan(0)); // right
      expect(warning.hazardType, isNull);
      expect(warning.metersToCorner, closeTo(7, 0.1));
      expect(route.warnAhead(_at(27), heading: null), isNull);
    });

    test('not on a leg under 12 m, nor for a slight bend', () {
      final short = _route([
        Waypoint(point: _at(10)),
        Waypoint(point: _at(10, 30)),
      ]);
      expect(short.warnAhead(_at(4), heading: null), isNull);
      final slight = _route([
        Waypoint(point: _at(33)),
        Waypoint(point: _at(63, 5)),
      ]);
      expect(slight.warnAhead(_at(26), heading: null), isNull);
    });

    test('before stairs: the hazard, but no turn to the floor above', () {
      final route = _route([
        Waypoint(point: _at(33), hazardType: 4),
        Waypoint(point: _at(33), floor: 1),
        Waypoint(point: _at(33, 33), floor: 1),
      ]);
      final warning = route.warnAhead(_at(26), heading: null)!;
      expect(warning.hazardType, 4);
      expect(warning.turn, isNull);
    });
  });
}

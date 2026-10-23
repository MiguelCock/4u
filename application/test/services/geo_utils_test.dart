import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:eyes4u/services/geo_utils.dart';

void main() {
  test('distance between the same point is zero', () {
    const point = LatLng(6.2442, -75.5812);
    expect(haversineMeters(point, point), closeTo(0, 0.001));
  });

  test('distance between two known points is approximately correct', () {
    // ~0.0001 deg of latitude is ~11.1m at the equator - a small, easy to
    // reason about offset rather than a real landmark pair.
    const a = LatLng(6.2442, -75.5812);
    const b = LatLng(6.2443, -75.5812);
    final distance = haversineMeters(a, b);
    expect(distance, closeTo(11.1, 1.0));
  });

  test('distance is symmetric', () {
    const a = LatLng(6.2442, -75.5812);
    const b = LatLng(6.2500, -75.5900);
    expect(haversineMeters(a, b), closeTo(haversineMeters(b, a), 0.001));
  });

  test('bearing is clockwise from north', () {
    const origin = LatLng(6.2442, -75.5812);
    expect(
      bearingDegrees(origin, const LatLng(6.2452, -75.5812)),
      closeTo(0, 0.5),
    );
    expect(
      bearingDegrees(origin, const LatLng(6.2442, -75.5802)),
      closeTo(90, 0.5),
    );
    expect(
      bearingDegrees(origin, const LatLng(6.2432, -75.5812)),
      closeTo(180, 0.5),
    );
    expect(
      bearingDegrees(origin, const LatLng(6.2442, -75.5822)),
      closeTo(270, 0.5),
    );
  });

  test('signed turn picks the short way round', () {
    expect(signedTurn(0, 90), 90);
    expect(signedTurn(90, 0), -90);
    expect(signedTurn(350, 10), 20);
    expect(signedTurn(10, 350), -20);
    expect(signedTurn(0, 180).abs(), 180);
  });

  group('route segments', () {
    // A straight segment due north, ~111 m long.
    const a = LatLng(6.2, -75.58);
    const b = LatLng(6.201, -75.58);
    // ~1.1 m east per 0.00001 deg of longitude at this latitude.
    LatLng east(LatLng p, double meters) =>
        LatLng(p.latitude, p.longitude + meters / 110574 / 0.99415);
    LatLng north(double meters) =>
        LatLng(a.latitude + meters / 111195, a.longitude);

    test('projection gives distance along and to the side', () {
      final p = projectOntoSegment(east(north(40), 6), a, b);
      expect(p.along, closeTo(40, 0.5));
      expect(p.length, closeTo(111.2, 0.5));
      expect(p.crossTrack, closeTo(6, 0.3)); // positive = right of travel
    });

    test('a sideways wobble near the line asks for no turn', () {
      // 8 m to the side, 30 m before the end: aiming at the waypoint itself
      // would need a ~15-27° turn; the guidance bearing is the path's.
      final here = east(north(81), 8);
      expect(signedTurn(0, bearingDegrees(here, b)).abs(), greaterThan(14));
      expect(guidanceBearing(here, a, b), closeTo(0, 0.5));
    });

    test('clearly off the path it steers back, gently', () {
      final here = east(north(40), 25);
      final turn = signedTurn(0, guidanceBearing(here, a, b));
      expect(turn, lessThan(-20)); // back to the left, towards the line
      expect(turn, greaterThan(-60)); // not a sharp U-turn
    });

    test('on the line it points straight along it', () {
      expect(guidanceBearing(north(30), a, b), closeTo(0, 0.5));
    });

    test('near the end it aims at the waypoint itself', () {
      final here = east(north(105), 3);
      expect(
        guidanceBearing(here, a, b),
        closeTo(bearingDegrees(here, b), 1e-9),
      );
    });
  });
}

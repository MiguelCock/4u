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
}

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
}

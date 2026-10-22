import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:eyes4u/services/map_tap.dart';

void main() {
  const center = LatLng(6.2, -75.58);
  final camera = MapCamera(
    crs: const Epsg3857(),
    center: center,
    zoom: 19,
    rotation: 0,
    nonRotatedSize: const Size(400, 800),
  );

  // Offsets are in screen pixels, converted through the camera itself, so
  // the test doesn't depend on metres-per-pixel at this zoom.
  LatLng offsetBy(double dx) => camera.screenOffsetToLatLng(
    camera.latLngToScreenOffset(center) + Offset(dx, 0),
  );

  final points = [
    {
      'id': 'near',
      'latitude': offsetBy(10).latitude,
      'longitude': offsetBy(10).longitude,
    },
    {
      'id': 'far',
      'latitude': offsetBy(200).latitude,
      'longitude': offsetBy(200).longitude,
    },
    {'id': 'nowhere'},
  ];

  test('a tap near a point picks it, even off the dot', () {
    final hit = nearestOnScreen(
      camera: camera,
      tapped: center,
      items: points,
      positionOf: anchorPosition,
    );
    expect(hit?['id'], 'near');
  });

  test('a tap far from every point picks nothing', () {
    final hit = nearestOnScreen(
      camera: camera,
      tapped: offsetBy(100),
      items: points,
      positionOf: anchorPosition,
    );
    expect(hit, isNull);
  });

  test('points without a position are skipped', () {
    expect(anchorPosition({'id': 'x'}), isNull);
  });
}

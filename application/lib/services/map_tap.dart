import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// The item drawn nearest to a map tap, if it's within [radiusPx] logical
/// pixels on screen. Much more forgiving than tapping a small dot exactly,
/// and used with `MapOptions.onTap` instead of a GestureDetector per
/// marker (which waited out flutter_map's double-tap timeout first).
T? nearestOnScreen<T>({
  required MapCamera camera,
  required LatLng tapped,
  required Iterable<T> items,
  required LatLng? Function(T item) positionOf,
  double radiusPx = 32,
}) {
  final tap = camera.latLngToScreenOffset(tapped);
  T? nearest;
  var nearestDistance = radiusPx;
  for (final item in items) {
    final position = positionOf(item);
    if (position == null) continue;
    final distance = (camera.latLngToScreenOffset(position) - tap).distance;
    if (distance <= nearestDistance) {
      nearestDistance = distance;
      nearest = item;
    }
  }
  return nearest;
}

/// An `anchor_points` row's position, or null when it has none.
LatLng? anchorPosition(Map<String, dynamic> point) {
  final lat = (point['latitude'] as num?)?.toDouble();
  final lng = (point['longitude'] as num?)?.toDouble();
  return lat == null || lng == null ? null : LatLng(lat, lng);
}

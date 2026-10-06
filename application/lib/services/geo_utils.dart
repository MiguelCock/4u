import 'dart:math';

import 'package:latlong2/latlong.dart';

const double _earthRadiusMeters = 6371000;

/// Straight-line distance between two points, in meters - same
/// equirectangular/haversine-family formula as the backend's
/// `_haversine_meters` (`backend-map-management/app/main.py`), used here to
/// pick the verified anchor point nearest the user's current GPS fix as a
/// trip's auto-selected start point.
double haversineMeters(LatLng a, LatLng b) {
  final phi1 = a.latitude * pi / 180;
  final phi2 = b.latitude * pi / 180;
  final dPhi = (b.latitude - a.latitude) * pi / 180;
  final dLambda = (b.longitude - a.longitude) * pi / 180;
  final h =
      sin(dPhi / 2) * sin(dPhi / 2) +
      cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2);
  return _earthRadiusMeters * 2 * atan2(sqrt(h), sqrt(1 - h));
}

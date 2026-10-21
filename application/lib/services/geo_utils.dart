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

/// Initial compass bearing from [a] to [b], in degrees clockwise from
/// north (0-360) - the direction a user standing at [a] has to face to
/// walk straight to [b].
double bearingDegrees(LatLng a, LatLng b) {
  final phi1 = a.latitude * pi / 180;
  final phi2 = b.latitude * pi / 180;
  final dLambda = (b.longitude - a.longitude) * pi / 180;
  final y = sin(dLambda) * cos(phi2);
  final x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda);
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

/// How far to turn from [heading] to face [bearing], in degrees from -180
/// to 180: positive means turn right, negative means turn left.
double signedTurn(double heading, double bearing) {
  final diff = (bearing - heading) % 360;
  return diff > 180 ? diff - 360 : diff;
}

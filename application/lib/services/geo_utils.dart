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

/// Metres east/north of [origin] (flat approximation, fine at campus scale).
({double x, double y}) _toLocal(LatLng origin, LatLng p) {
  final x =
      (p.longitude - origin.longitude) *
      pi /
      180 *
      cos(origin.latitude * pi / 180) *
      _earthRadiusMeters;
  final y = (p.latitude - origin.latitude) * pi / 180 * _earthRadiusMeters;
  return (x: x, y: y);
}

/// Where [p] falls along the route segment [a]→[b]: [along] metres from
/// [a] (negative before it, beyond [length] past [b]) and [crossTrack]
/// metres to the side (positive = right of the direction of travel).
class SegmentProjection {
  final double along;
  final double length;
  final double crossTrack;

  const SegmentProjection(this.along, this.length, this.crossTrack);
}

SegmentProjection projectOntoSegment(LatLng p, LatLng a, LatLng b) {
  final end = _toLocal(a, b);
  final point = _toLocal(a, p);
  final length = sqrt(end.x * end.x + end.y * end.y);
  if (length < 1e-6) {
    return SegmentProjection(0, 0, sqrt(point.x * point.x + point.y * point.y));
  }
  final ux = end.x / length;
  final uy = end.y / length;
  final along = point.x * ux + point.y * uy;
  // Right of travel: rotate the direction by -90° (east/north frame).
  final cross = point.x * uy - point.y * ux;
  return SegmentProjection(along, length, cross);
}

/// The point [meters] along [a]→[b] from [a], clamped to the segment.
LatLng pointAlongSegment(LatLng a, LatLng b, double meters) {
  final length = haversineMeters(a, b);
  if (length < 1e-6) return b;
  final t = (meters / length).clamp(0.0, 1.0);
  return LatLng(
    a.latitude + (b.latitude - a.latitude) * t,
    a.longitude + (b.longitude - a.longitude) * t,
  );
}

/// The direction to walk to follow segment [a]→[b] from [here].
///
/// Aiming at the next waypoint itself swung the needed turn by 30° or more
/// whenever the position wobbled sideways near it (a field-test symptom).
/// Within [toleranceMeters] of the line - GPS and correction noise - this
/// is just the segment's own direction, so a wobble asks for no turn at
/// all. Further off, it steers back gently towards a point
/// [lookAheadMeters] ahead along the segment. Near the segment's end it
/// aims at [b], so the next leg's turn comes at the right place.
double guidanceBearing(
  LatLng here,
  LatLng a,
  LatLng b, {
  double toleranceMeters = 10,
  double lookAheadMeters = 20,
}) {
  final projection = projectOntoSegment(here, a, b);
  final remaining = projection.length - projection.along;
  if (projection.length < 1e-6 || remaining <= lookAheadMeters / 2) {
    return bearingDegrees(here, b);
  }
  if (projection.crossTrack.abs() <= toleranceMeters) {
    return bearingDegrees(a, b);
  }
  final target = pointAlongSegment(
    a,
    b,
    max(0, projection.along) + lookAheadMeters,
  );
  return bearingDegrees(here, target);
}

/// Indexes into [points] (a route, start first) where guidance should
/// stop: each corner where the direction changes by more than
/// [turnDegrees], every index in [keep], and the last point.
///
/// Anchor points are captured every 6-7 m, so a field test spoke
/// "continue straight 6 meters" at every one of them and, reaching each
/// from 20 m away, announced corners ~15 m early. Guidance now walks from
/// corner to corner. A corner is judged against the direction since the
/// last kept point, so a gradual curve still gets one once it adds up.
List<int> routeCorners(
  List<LatLng> points, {
  double turnDegrees = 30,
  Set<int> keep = const {},
}) {
  if (points.length < 2) return [for (var i = 0; i < points.length; i++) i];
  final corners = <int>[0];
  for (var i = 1; i < points.length - 1; i++) {
    final from = points[corners.last];
    if (keep.contains(i) ||
        signedTurn(
              bearingDegrees(from, points[i]),
              bearingDegrees(points[i], points[i + 1]),
            ).abs() >
            turnDegrees) {
      corners.add(i);
    }
  }
  corners.add(points.length - 1);
  return corners;
}

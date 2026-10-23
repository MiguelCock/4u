import 'package:latlong2/latlong.dart';

import 'geo_utils.dart';

/// How far a session's positions were from where the user really was, for
/// admin test walks: the admin walks the planned route exactly, so
/// distance from the route is correction error, and at each checkpoint
/// (start, corners, destination - see test_walk.dart) the true position is
/// the route point itself.

/// Distance (meters) from [p] to the nearest point of [path].
double distanceToPath(LatLng p, List<LatLng> path) {
  if (path.isEmpty) return double.nan;
  if (path.length == 1) return haversineMeters(p, path.first);
  var best = double.infinity;
  for (var i = 0; i < path.length - 1; i++) {
    final projection = projectOntoSegment(p, path[i], path[i + 1]);
    final double d;
    if (projection.along <= 0) {
      d = haversineMeters(p, path[i]);
    } else if (projection.along >= projection.length) {
      d = haversineMeters(p, path[i + 1]);
    } else {
      d = projection.crossTrack.abs();
    }
    if (d < best) best = d;
  }
  return best;
}

class ErrorStats {
  final int count;
  final double mean;
  final double median;
  final double p90;

  const ErrorStats._(this.count, this.mean, this.median, this.p90);

  static ErrorStats? of(Iterable<double> values) {
    final v = values.where((x) => x.isFinite).toList()..sort();
    if (v.isEmpty) return null;
    final mean = v.reduce((a, b) => a + b) / v.length;
    final median = v.length.isOdd
        ? v[v.length ~/ 2]
        : (v[v.length ~/ 2 - 1] + v[v.length ~/ 2]) / 2;
    final p90 = v[((v.length - 1) * 0.9).round()];
    return ErrorStats._(v.length, mean, median, p90);
  }
}

class RouteErrorSummary {
  /// Distance from the planned route, every tick.
  final ErrorStats? raw;
  final ErrorStats? corrected;

  /// Share of ticks (with both) where the corrected position was closer to
  /// the route than raw GPS.
  final double? correctedCloserShare;

  /// Full error at the checkpoints the admin tapped.
  final ErrorStats? checkpointRaw;
  final ErrorStats? checkpointCorrected;

  const RouteErrorSummary._({
    this.raw,
    this.corrected,
    this.correctedCloserShare,
    this.checkpointRaw,
    this.checkpointCorrected,
  });

  bool get isEmpty => raw == null && checkpointRaw == null;

  /// [logs] are navigation_logs rows (with `debug`), [path] the planned
  /// route, start first.
  static RouteErrorSummary compute(
    List<Map<String, dynamic>> logs,
    List<LatLng> path,
  ) {
    if (path.length < 2) return const RouteErrorSummary._();
    final rawErrors = <double>[];
    final correctedErrors = <double>[];
    var closer = 0;
    var both = 0;
    for (final log in logs) {
      final raw = _latLng(log['gps_lat'], log['gps_long']);
      final corrected = _latLng(log['corrected_lat'], log['corrected_long']);
      final rawError = raw == null ? null : distanceToPath(raw, path);
      final correctedError = corrected == null
          ? null
          : distanceToPath(corrected, path);
      if (rawError != null) rawErrors.add(rawError);
      if (correctedError != null) correctedErrors.add(correctedError);
      if (rawError != null && correctedError != null) {
        both++;
        if (correctedError < rawError) closer++;
      }
    }

    final corners = routeCorners(path);
    final taps = checkpointEvents(logs);
    final checkpointRaw = <double>[];
    final checkpointCorrected = <double>[];
    for (final tap in taps) {
      final index = tap['index'] as int;
      if (index < 0 || index >= corners.length) continue;
      final truth = path[corners[index]];
      final raw = _pair(tap['raw']);
      final corrected = _pair(tap['corrected']);
      if (raw != null) checkpointRaw.add(haversineMeters(raw, truth));
      if (corrected != null) {
        checkpointCorrected.add(haversineMeters(corrected, truth));
      }
    }
    return RouteErrorSummary._(
      raw: ErrorStats.of(rawErrors),
      corrected: ErrorStats.of(correctedErrors),
      correctedCloserShare: both == 0 ? null : closer / both,
      checkpointRaw: ErrorStats.of(checkpointRaw),
      checkpointCorrected: ErrorStats.of(checkpointCorrected),
    );
  }
}

/// The checkpoint taps still standing (an undo cancels the latest tap of
/// its index), in the order they were made.
List<Map<String, dynamic>> checkpointEvents(List<Map<String, dynamic>> logs) {
  final events = <Map<String, dynamic>>[
    for (final log in logs)
      for (final event
          in ((log['debug'] as Map?)?['events'] as List? ?? const []))
        if (event is Map &&
            (event['type'] == 'checkpoint' ||
                event['type'] == 'checkpoint_undo') &&
            event['index'] is int)
          event.cast<String, dynamic>(),
  ]..sort((a, b) => '${a['at']}'.compareTo('${b['at']}'));
  final standing = <Map<String, dynamic>>[];
  for (final event in events) {
    if (event['type'] == 'checkpoint') {
      standing.add(event);
    } else {
      final i = standing.lastIndexWhere((e) => e['index'] == event['index']);
      if (i >= 0) standing.removeAt(i);
    }
  }
  return standing;
}

LatLng? _latLng(Object? lat, Object? lng) =>
    lat is num && lng is num ? LatLng(lat.toDouble(), lng.toDouble()) : null;

LatLng? _pair(Object? value) =>
    value is List && value.length == 2 ? _latLng(value[0], value[1]) : null;

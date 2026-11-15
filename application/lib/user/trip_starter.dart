import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as path;

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/camera_helper.dart';
import '../services/destinations.dart';
import '../services/geo_utils.dart';
import '../services/image_utils.dart';
import '../services/location_service.dart';

/// Which end of a route isn't connected, from backend-route-management's
/// 404 detail.
enum NoPathEnd { start, destination, unknown }

NoPathEnd noPathEnd(String? detail) {
  if (detail == null) return NoPathEnd.unknown;
  if (detail.startsWith('Your starting point')) return NoPathEnd.start;
  if (detail.startsWith("The destination isn't")) {
    return NoPathEnd.destination;
  }
  return NoPathEnd.unknown;
}

/// The verified anchor in [anchors] nearest [from], or null if none has a
/// position.
Map<String, dynamic>? nearestAnchor(
  Iterable<Map<String, dynamic>> anchors,
  LatLng from,
) {
  Map<String, dynamic>? nearest;
  double? nearestDistance;
  for (final anchor in anchors) {
    final position = anchorPosition(anchor);
    if (position == null) continue;
    final distance = haversineMeters(from, position);
    if (nearestDistance == null || distance < nearestDistance) {
      nearestDistance = distance;
      nearest = anchor;
    }
  }
  return nearest;
}

/// Whether [start] already is [end]: the same point, or inside the building
/// chosen as a whole.
bool alreadyAt(Map<String, dynamic> start, Map<String, dynamic> end) =>
    start['id'] == end['id'] ||
    (end['whole_building'] == true &&
        start['building_id'] == end['building_id']);

/// How [TripStarter.planTrip] ended. The screen says each in its own words.
sealed class TripOutcome {
  const TripOutcome();
}

/// The route was found: start the trip.
class TripFound extends TripOutcome {
  const TripFound(this.route);
  final Map<String, dynamic> route;
}

/// No GPS fix: location is off ([LocationError.serviceDisabled]), not
/// allowed (another [error]), or simply no fix yet (null).
class TripNoGps extends TripOutcome {
  const TripNoGps(this.error);
  final LocationError? error;
}

/// No verified point near enough to start from.
class TripNoStart extends TripOutcome {
  const TripNoStart();
}

/// The user is already at the destination.
class TripAlreadyThere extends TripOutcome {
  const TripAlreadyThere();
}

/// No walkable path between the start and the destination (a 404).
class TripNoPath extends TripOutcome {
  const TripNoPath(this.end);
  final NoPathEnd end;
}

/// The server couldn't be reached, or refused.
class TripFailed extends TripOutcome {
  const TripFailed(this.error);
  final ApiException error;
}

/// The user backed out (of the floor question), or the screen closed.
class TripCancelled extends TripOutcome {
  const TripCancelled();
}

/// What the screen says for [outcome], or null for a found route or a
/// cancel (nothing to say). [apiError] words a server failure.
String? tripOutcomeMessage(
  AppLocalizations l10n,
  TripOutcome outcome, {
  required Map<String, dynamic> destination,
  required String Function(ApiException error) apiError,
}) => switch (outcome) {
  TripFound() || TripCancelled() => null,
  TripNoGps(error: LocationError.serviceDisabled) =>
    l10n.locationServiceDisabledError,
  TripNoGps(error: null) => l10n.homeErrorNoGpsFix,
  TripNoGps() => l10n.locationPermissionDeniedError,
  TripNoStart() => l10n.homeErrorNoVerifiedAnchors,
  TripAlreadyThere() => l10n.homeErrorAlreadyAtDestination(
    destination['location_description'] as String? ??
        destination['id'] as String,
  ),
  TripNoPath(end: NoPathEnd.start) => l10n.homeErrorNoPathStart,
  TripNoPath(end: NoPathEnd.destination) => l10n.homeErrorNoPathDestination,
  TripNoPath() => l10n.homeErrorNoPath,
  TripFailed(:final error) => l10n.homeErrorFailedToFindRoute(apiError(error)),
};

/// Where a trip starts, and the route to its destination (#268). It holds
/// the map the home screen offers (verified, connected points in active
/// buildings), the start (nearest the live GPS fix, or checked with the
/// camera), the floor the user said they're on, and asks the server for
/// the route. What's said about it, and the errors, are the screen's.
/// Came out of `UserHomeScreen`.
class TripStarter extends ChangeNotifier {
  TripStarter({
    MapManagementApi? mapApi,
    RouteManagementApi? routeApi,
    PositioningApi? positioningApi,
    LocationService? locationService,
    Future<CameraController?> Function()? camera,
    DateTime Function()? now,
  }) : _mapApi = mapApi ?? MapManagementApi(),
       _routeApi = routeApi ?? RouteManagementApi(),
       _positioningApi = positioningApi ?? PositioningApi(),
       location = locationService ?? LocationService(),
       _camera = camera ?? initCamera,
       _now = now ?? DateTime.now;

  final MapManagementApi _mapApi;
  final RouteManagementApi _routeApi;
  final PositioningApi _positioningApi;
  final LocationService location;
  final Future<CameraController?> Function() _camera;
  final DateTime Function() _now;
  bool _disposed = false;

  /// Photos taken by the start-point check, and the minimum gap between
  /// them. Each one goes through the same Kalman filter, so later photos
  /// refine earlier ones; one photo alone barely moved the position.
  static const int checkPhotos = 6;
  static const Duration checkInterval = Duration(milliseconds: 900);

  /// A checked start is kept (not replaced by the raw-GPS nearest point)
  /// until the user moves this far from where it was checked, and so is
  /// the floor they said...
  static const double keepWithinMeters = 15;

  /// ...and Find route reuses a check for this long instead of checking
  /// again.
  static const Duration checkFreshFor = Duration(seconds: 60);

  /// Verified, connected points in active buildings of active universities
  /// - the only ones offered as a start or a destination. An unconnected
  /// start made every route at Icesi fail (2026-11-03).
  List<Map<String, dynamic>> anchors = [];
  List<Map<String, dynamic>> buildings = [];
  Map<String, String> buildingNames = {};

  /// Known once the universities have loaded.
  Set<String>? activeBuildings;

  Map<String, dynamic>? _start;
  Map<String, dynamic>? get start => _start;

  /// The camera check is running, and on which photo (0 before the first).
  bool _locating = false;
  bool get locating => _locating;
  int _progress = 0;
  int get progress => _progress;

  DateTime? _checkedAt;
  LatLng? _checkedFrom;
  int? _answeredFloor;
  LatLng? _answeredFloorFrom;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Loads the map. Throws [ApiException].
  Future<void> load() async {
    final results = await Future.wait([
      _mapApi.get('/places'),
      _mapApi.get('/buildings'),
      _mapApi.get('/anchor-points'),
    ]);
    final connected = await fetchConnectedAnchorIds(_mapApi);
    final loaded = (results[1] as List).cast<Map<String, dynamic>>();
    buildings = loaded;
    buildingNames = _namesOf(loaded);
    final active = activeBuildingIds(
      (results[0] as List).cast<Map<String, dynamic>>(),
      loaded,
    );
    activeBuildings = active;
    anchors = (results[2] as List)
        .cast<Map<String, dynamic>>()
        .where(
          (a) =>
              a['status'] == 'verified' &&
              active.contains(a['building_id']) &&
              (connected?.contains(a['id']) ?? true),
        )
        .toList();
  }

  static Map<String, String> _namesOf(List<Map<String, dynamic>> buildings) => {
    for (final b in buildings) b['id'] as String: b['name'] as String? ?? '',
  };

  /// Best-effort early load, so the start is known before the user does
  /// anything. Find route loads again and reports a real failure.
  Future<void> loadQuietly() async {
    try {
      await load();
      if (_disposed) return;
      final position = location.lastPosition;
      if (position != null) onPosition(position);
    } on ApiException {
      // Reported later by Find route if it's still failing then.
    }
  }

  /// Building names before a listen: they help tell same-named places
  /// apart, so a failure only leaves them out.
  Future<void> ensureLoaded() async {
    if (anchors.isEmpty) await loadQuietly();
    if (buildingNames.isNotEmpty) return;
    try {
      buildings = (await _mapApi.get('/buildings') as List)
          .cast<Map<String, dynamic>>();
      buildingNames = _namesOf(buildings);
    } on ApiException {
      // Only for telling same-named places apart.
    }
  }

  /// A new GPS fix: the nearest point becomes the start, unless the screen
  /// is [busy] (finding a route), the camera check is running, or a
  /// checked start is still where the user is.
  void onPosition(Position position, {bool busy = false}) {
    if (_disposed || anchors.isEmpty || busy || _locating) return;
    final here = position.latLng;
    final checkedFrom = _checkedFrom;
    if (checkedFrom != null &&
        haversineMeters(checkedFrom, here) < keepWithinMeters) {
      return;
    }
    _checkedAt = null;
    _checkedFrom = null;
    final nearest = nearestAnchor(anchors, here);
    if (nearest?['id'] != _start?['id']) {
      _start = nearest;
      _changed();
    }
  }

  /// Whether the last camera check can be reused instead of running again.
  bool get checkIsFresh {
    final checkedAt = _checkedAt;
    final from = _checkedFrom;
    final position = location.lastPosition;
    if (_start == null || checkedAt == null || from == null) return false;
    if (_now().difference(checkedAt) > checkFreshFor) return false;
    return position == null ||
        haversineMeters(from, position.latLng) < keepWithinMeters;
  }

  /// Runs the camera check and makes the anchor nearest its result the
  /// start. [beforePhotos] runs first, once the map has loaded (the screen
  /// says to hold the phone up and turn: in full, before the first photo).
  /// Throws [ApiException] if the map can't be loaded.
  Future<({Map<String, dynamic>? start, int matched})> locateStart({
    Future<void> Function()? beforePhotos,
  }) async {
    await load();
    if (_disposed) return (start: null, matched: 0);
    _locating = true;
    _progress = 0;
    _changed();
    try {
      await beforePhotos?.call();
      if (_disposed) return (start: null, matched: 0);
      final check = await _checkPosition();
      if (_disposed) return (start: null, matched: 0);
      final position = check.position;
      final found = position == null ? null : nearestAnchor(anchors, position);
      _start = found;
      if (found != null) {
        _checkedAt = _now();
        _checkedFrom = position;
      }
      return (start: found, matched: check.matched);
    } finally {
      _locating = false;
      _changed();
    }
  }

  /// Multi-photo position check for the start point. Each photo plus the
  /// current GPS fix goes to backend-positioning's session
  /// `POST /correct_position` under a throwaway key: that endpoint only
  /// uses session_id to key its in-memory filter (no DB lookup), so the
  /// photos accumulate in one filter and the result is the fused position.
  /// The filter expires on its own (the positioning service's session TTL).
  /// Without a camera, or if every photo fails, falls back to raw GPS.
  Future<({LatLng? position, int matched})> _checkPosition() async {
    final key =
        'start-check-${_now().microsecondsSinceEpoch}-'
        '${Random().nextInt(1 << 32)}';
    CameraController? controller;
    LatLng? fused;
    var matched = 0;
    try {
      controller = await _camera();
      if (controller != null) {
        for (var i = 0; i < checkPhotos; i++) {
          if (_disposed) break;
          _progress = i + 1;
          _changed();
          final started = DateTime.now();
          final position = location.lastPosition;
          if (position != null) {
            try {
              final image = await controller.takePicture();
              final bytes = await image.readAsBytes();
              if (!isFrameBlocked(bytes)) {
                final result =
                    await _positioningApi
                            .postMultipart(
                              '/correct_position',
                              fieldName: 'photo',
                              bytes: bytes,
                              filename: path.basename(image.path),
                              fields: {
                                'session_id': key,
                                'latitude': position.latitude.toString(),
                                'longitude': position.longitude.toString(),
                                'accuracy': position.accuracy.toString(),
                                // No compass here, and the GPS course is
                                // meaningless while turning on the spot, so
                                // no heading: the backend skips that gate.
                                'gps_time': position.timestamp
                                    .toUtc()
                                    .toIso8601String(),
                              },
                            )
                            .timeout(const Duration(seconds: 10))
                        as Map<String, dynamic>;
                fused = LatLng(
                  (result['corrected_lat'] as num).toDouble(),
                  (result['corrected_long'] as num).toDouble(),
                );
                if (result['anchor_match_id'] != null) matched++;
              }
            } catch (_) {
              // One bad photo or request just doesn't count.
            }
          }
          final elapsed = DateTime.now().difference(started);
          if (elapsed < checkInterval) {
            await Future<void>.delayed(checkInterval - elapsed);
          }
        }
      }
    } finally {
      await controller?.dispose();
    }
    final raw = location.lastPosition;
    return (position: fused ?? raw?.latLng, matched: matched);
  }

  /// The floor the user said they're on, if it's one of [floors] and they
  /// haven't moved [keepWithinMeters] since.
  int? rememberedFloor(List<int> floors, LatLng here) {
    final answered = _answeredFloor;
    final from = _answeredFloorFrom;
    if (answered != null &&
        from != null &&
        floors.contains(answered) &&
        haversineMeters(from, here) < keepWithinMeters) {
      return answered;
    }
    return null;
  }

  /// The user said they're on [floor], at [here]: kept until they've moved
  /// [keepWithinMeters] (see [rememberedFloor]).
  void rememberFloor(int floor, LatLng here) {
    _answeredFloor = floor;
    _answeredFloorFrom = here;
  }

  /// The start becomes the nearest point to [here] on [floor].
  Map<String, dynamic>? startOnFloor(int floor, LatLng here) {
    _start = nearestAnchor(
      anchors.where((a) => (a['floor'] as int? ?? 0) == floor),
      here,
    );
    _changed();
    return _start;
  }

  /// From here to [end]: waits for a GPS fix, checks the start ([locate],
  /// the screen's camera check, unless a fresh one is at hand), asks which
  /// floor when several are near ([askFloor]: null backs out), and asks the
  /// server for the route. Everyone gets the camera check of the start.
  Future<TripOutcome> planTrip(
    Map<String, dynamic> end, {
    required Future<Map<String, dynamic>?> Function() locate,
    required Future<int?> Function(List<int> floors, LatLng here) askFloor,
  }) async {
    // Waits for a fix (and re-checks location) instead of giving up on the
    // first try: in battery saver that said "GPS off" while it was on.
    final position = await location.ensureReady();
    if (_disposed) return const TripCancelled();
    if (position == null) return TripNoGps(location.lastError);
    try {
      final here = position.latLng;
      var from = checkIsFresh ? _start : await locate();
      if (_disposed) return const TripCancelled();
      // GPS can't tell floors apart: the nearest point may be overhead.
      final floors = floorsNear(anchors, here);
      if (from != null && floors.length > 1) {
        final floor = await askFloor(floors, here);
        if (_disposed || floor == null) return const TripCancelled();
        from = startOnFloor(floor, here);
      }
      if (from == null) return const TripNoStart();
      if (alreadyAt(from, end)) return const TripAlreadyThere();
      final route = await findRoute(from, end);
      if (_disposed) return const TripCancelled();
      return TripFound(route);
    } on ApiException catch (e) {
      return e.statusCode == 404
          ? TripNoPath(noPathEnd(e.detail))
          : TripFailed(e);
    }
  }

  /// The route from [start] to [end] (`find_or_create`): the same pair gets
  /// the same answer, so it's safe to send again after a dropped
  /// connection. A whole building goes as `end_building_id`, and the server
  /// picks its door. Throws [ApiException] (404: no walkable path, see
  /// [noPathEnd]).
  Future<Map<String, dynamic>> findRoute(
    Map<String, dynamic> start,
    Map<String, dynamic> end,
  ) async =>
      await _routeApi.post('/routes/find_or_create', {
            'start_anchor_id': start['id'],
            if (end['whole_building'] == true)
              'end_building_id': end['building_id']
            else
              'end_anchor_id': end['id'],
          }, retry: true)
          as Map<String, dynamic>;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

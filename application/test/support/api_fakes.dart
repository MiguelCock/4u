import 'dart:async';

import 'package:clock/clock.dart';
import 'package:eyes4u/services/api_service.dart';
import 'package:eyes4u/services/location_service.dart';
import 'package:geolocator/geolocator.dart';

/// Stand-ins for the gateway's APIs and the phone's location (#268). Each
/// API answers from the data it's given; anything else is a 404. Their
/// constructors read `API_GATEWAY_URL`, so tests call
/// `dotenv.testLoad(fileInput: '')` first.

class FakeMapApi extends MapManagementApi {
  FakeMapApi({
    this.places = const [],
    this.buildings = const [],
    this.anchors = const [],
    this.connections = const [],
    this.failConnections = false,
  });

  List<Map<String, dynamic>> places;
  List<Map<String, dynamic>> buildings;
  List<Map<String, dynamic>> anchors;
  List<Map<String, dynamic>> connections;
  bool failConnections;

  @override
  Future<dynamic> get(String path) async => switch (path) {
    '/places' => places,
    '/buildings' => buildings,
    '/anchor-points' => anchors,
    '/anchor-point-connections' when !failConnections => connections,
    _ => _onePoint(path),
  };

  /// `/anchor-points/{id}` and `/anchor-points/{id}/connections`, as an
  /// older server answers a route's points (no `by-ids`).
  Object _onePoint(String path) {
    final match = RegExp(
      r'^/anchor-points/([^/?]+)(/connections)?$',
    ).firstMatch(path);
    final id = match?.group(1);
    if (id == null || id == 'by-ids') throw ApiException(404, path);
    if (match!.group(2) != null) {
      return [
        for (final c in connections)
          if (c['anchor_point_a_id'] == id || c['anchor_point_b_id'] == id) c,
      ];
    }
    for (final a in anchors) {
      if (a['id'] == id) return a;
    }
    throw ApiException(404, path);
  }
}

class FakeNavigationApi extends NavigationManagementApi {
  FakeNavigationApi({this.sessions = const []});

  List<Map<String, dynamic>> sessions;
  final patches = <String, Map<String, dynamic>>{};

  @override
  Future<dynamic> get(String path) async =>
      path == '/sessions/active' ? sessions : throw ApiException(404, path);

  @override
  Future<dynamic> patch(String path, Map<String, dynamic> body) async {
    patches[path] = body;
    return body;
  }

  /// Every POST, in order, as (path, body).
  final posts = <(String, Map<String, dynamic>)>[];

  @override
  Future<dynamic> post(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
    bool retry = false,
  }) async {
    posts.add((path, body));
    // Supabase's insert result, as the backend returns it: a list.
    return path == '/sessions'
        ? [
            {'id': 's1', ...body},
          ]
        : body;
  }
}

class FakeRouteApi extends RouteManagementApi {
  FakeRouteApi({this.routes = const {}, this.answer});

  /// `GET /routes/{id}` answers.
  Map<String, Map<String, dynamic>> routes;

  /// What `find_or_create` returns, or null for a 404.
  Map<String, dynamic>? answer;
  final posts = <Map<String, dynamic>>[];

  @override
  Future<dynamic> get(String path) async {
    final route = routes[path.replaceFirst('/routes/', '')];
    if (route == null) throw ApiException(404, path);
    return route;
  }

  @override
  Future<dynamic> post(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
    bool retry = false,
  }) async {
    posts.add(body);
    final route = answer;
    if (route == null) {
      throw ApiException(404, '{"detail": "No walkable path found"}');
    }
    return route;
  }
}

class FakePositioningApi extends PositioningApi {}

/// Location that's off: no fixes unless a test sets `lastPosition`.
class NoLocation extends LocationPlatform {
  @override
  Future<bool> isServiceEnabled() async => false;
  @override
  Stream<Position> positions() => const Stream.empty();
  @override
  Stream<ServiceStatus> serviceStatus() => const Stream.empty();
}

/// Location that's on, at [here]; [moveTo] walks the user somewhere else.
class FixedLocation extends LocationPlatform {
  FixedLocation(this.here);

  Position here;
  final _fixes = StreamController<Position>.broadcast();

  void moveTo(Position next) {
    here = next;
    _fixes.add(next);
  }

  @override
  Future<bool> isServiceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<Position?> lastKnown() async => here;
  @override
  Future<Position> current(Duration timeLimit) async => here;
  @override
  Stream<Position> positions() => _fixes.stream;
  @override
  Stream<ServiceStatus> serviceStatus() => const Stream.empty();
}

/// A GPS fix taken now (the test's clock, so it's never stale).
Position fix(double latitude, double longitude) => Position(
  latitude: latitude,
  longitude: longitude,
  timestamp: clock.now(),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

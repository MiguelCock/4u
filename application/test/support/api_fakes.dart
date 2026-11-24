import 'dart:async';

import 'package:clock/clock.dart';
import 'package:eyes4u/services/api_service.dart';
import 'package:eyes4u/services/location_service.dart';
import 'package:geolocator/geolocator.dart';

/// Stand-ins for the gateway's APIs and the phone's location (#268). Each
/// API answers from the data it's given; anything else is a 404. Their
/// constructors read `API_GATEWAY_URL`, so tests call
/// `dotenv.testLoad(fileInput: '')` first.

/// Every write a fake API was asked for, in order, as (method, path, body).
typedef ApiWrite = (String, String, Map<String, dynamic>?);

/// Records writes and answers each with its own body.
mixin RecordsWrites on ApiService {
  final writes = <ApiWrite>[];

  /// The paths written with [method] ('POST', 'PATCH', 'DELETE').
  List<String> paths(String method) => [
    for (final (m, path, _) in writes)
      if (m == method) path,
  ];

  @override
  Future<dynamic> post(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
    bool retry = false,
  }) async {
    writes.add(('POST', path, body));
    return body;
  }

  @override
  Future<dynamic> patch(String path, Map<String, dynamic> body) async {
    writes.add(('PATCH', path, body));
    return body;
  }

  @override
  Future<dynamic> delete(String path) async {
    writes.add(('DELETE', path, null));
    return null;
  }
}

class FakeMapApi extends MapManagementApi with RecordsWrites {
  FakeMapApi({
    this.places = const [],
    this.buildings = const [],
    this.anchors = const [],
    this.photos = const [],
    this.connections = const [],
    this.failConnections = false,
    this.changes,
  });

  List<Map<String, dynamic>> places;
  List<Map<String, dynamic>> buildings;
  List<Map<String, dynamic>> anchors;
  List<Map<String, dynamic>> photos;
  List<Map<String, dynamic>> connections;
  bool failConnections;

  /// `GET /changes?since=` (A5), given the `since` asked; null: a server
  /// without it (404).
  Map<String, dynamic> Function(String since)? changes;

  @override
  Future<dynamic> get(String path) async {
    if (path.startsWith('/changes?since=')) {
      final answer = changes;
      if (answer == null) throw ApiException(404, path);
      return answer(Uri.decodeQueryComponent(path.substring(15)));
    }
    return switch (path) {
      '/places' => places,
      '/buildings' => buildings,
      '/anchor-points' => anchors,
      '/anchor-point-photos' => photos,
      '/anchor-point-connections' when !failConnections => connections,
      _ => _onePoint(path),
    };
  }

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

class FakePositioningApi extends PositioningApi {
  FakePositioningApi({this.answer});

  /// What `/correct_position` answers; null for a 503.
  Map<String, dynamic>? answer;

  /// Each photo sent: its fields.
  final sent = <Map<String, String>>[];

  @override
  Future<dynamic> postMultipart(
    String path, {
    required String fieldName,
    required List<int> bytes,
    required String filename,
    Map<String, String>? fields,
    Duration? timeout,
  }) async {
    sent.add({'path': path, 'field': fieldName, ...?fields});
    return answer ?? (throw ApiException(503, ''));
  }
}

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

class FakeUserApi extends UserManagementApi with RecordsWrites {
  FakeUserApi({this.profiles = const [], this.orphaned = const []});

  List<Map<String, dynamic>> profiles;
  List<Map<String, dynamic>> orphaned;

  @override
  Future<dynamic> get(String path) async => switch (path) {
    '/profiles' => profiles,
    '/profiles/orphaned' => orphaned,
    _ =>
      profiles.where((p) => '/profiles/${p['id']}' == path).firstOrNull ??
          (throw ApiException(404, path)),
  };
}

class FakeAiTrainingApi extends AiTrainingApi with RecordsWrites {
  FakeAiTrainingApi({this.indexedPhotoIds});

  /// What `/index_status` says is searchable; null: a 404.
  Set<String>? indexedPhotoIds;

  @override
  Future<dynamic> get(String path) async {
    final ids = indexedPhotoIds;
    if (path == '/index_status' && ids != null) {
      return {
        'photo_ids': [...ids],
      };
    }
    throw ApiException(404, path);
  }
}

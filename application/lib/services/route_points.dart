import 'api_service.dart';

/// A route's points and the connections around them, as NavigationScreen
/// needs them before guidance can start (E2).
class RoutePoints {
  const RoutePoints(this.anchors, this.connections);

  /// One per route id, in order; null where a point is gone.
  final List<Map<String, dynamic>?> anchors;

  /// For each point but the last, the connections touching it.
  final List<List<Map<String, dynamic>>> connections;
}

/// Spreads `GET /anchor-points/by-ids`' answer over the route's ids, in the
/// shape the per-point requests gave.
RoutePoints routePointsFromBatch(List<String> ids, Map<String, dynamic> body) {
  final byId = {
    for (final point in (body['points'] as List? ?? const []))
      (point as Map)['id'] as String: Map<String, dynamic>.from(point),
  };
  final connections = [
    for (final c in (body['connections'] as List? ?? const []))
      Map<String, dynamic>.from(c as Map),
  ];
  return RoutePoints(
    [for (final id in ids) byId[id]],
    [
      for (final id in ids.take(ids.length - 1))
        [
          for (final c in connections)
            if (c['anchor_point_a_id'] == id || c['anchor_point_b_id'] == id) c,
        ],
    ],
  );
}

/// One request when the server has `by-ids`. Otherwise, as before: one per
/// point and one per point's connections (about 40 for a route), which an
/// older server still answers.
Future<RoutePoints> fetchRoutePoints(ApiService api, List<String> ids) async {
  try {
    final body = await api.get('/anchor-points/by-ids?ids=${ids.join(',')}');
    if (body is Map<String, dynamic>) return routePointsFromBatch(ids, body);
  } on ApiException {
    // An older server, or a blip: the per-point way below still works.
  }
  final anchors = await Future.wait(
    ids.map((id) async {
      try {
        return await api.get('/anchor-points/$id') as Map<String, dynamic>;
      } on ApiException {
        // A missing point just means no line or announcement for it.
        return null;
      }
    }),
  );
  final connections = await Future.wait(
    ids.take(ids.length - 1).map((id) async {
      try {
        return (await api.get('/anchor-points/$id/connections') as List)
            .cast<Map<String, dynamic>>();
      } on ApiException {
        return const <Map<String, dynamic>>[];
      }
    }),
  );
  return RoutePoints(anchors, connections);
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:eyes4u/services/api_service.dart';
import 'package:eyes4u/services/route_points.dart';

ApiService _api(Future<http.Response> Function(http.Request) handler) =>
    ApiService(
      'http://gateway.example/map',
      client: MockClient(handler),
      getAccessToken: () => null,
      refreshSession: () async {},
      retryDelay: Duration.zero,
    );

void main() {
  const ids = ['a', 'b', 'c'];

  test('the batch answer is spread over the route in order', () {
    final route = routePointsFromBatch(ids, {
      'points': [
        {'id': 'c'},
        {'id': 'a'},
      ],
      'connections': [
        {'anchor_point_a_id': 'a', 'anchor_point_b_id': 'b', 'notes': 'x'},
        {'anchor_point_a_id': 'b', 'anchor_point_b_id': 'c'},
      ],
    });
    expect(route.anchors.map((p) => p?['id']), ['a', null, 'c']);
    expect(route.connections, hasLength(2));
    expect(route.connections[0].single['notes'], 'x');
    expect(route.connections[1], hasLength(2));
  });

  test('one request when the server has by-ids', () async {
    final paths = <String>[];
    final route = await fetchRoutePoints(
      _api((request) async {
        paths.add(request.url.path);
        return http.Response(
          jsonEncode({
            'points': [
              for (final id in ids) {'id': id},
            ],
            'connections': [],
          }),
          200,
        );
      }),
      ids,
    );
    expect(paths, ['/map/anchor-points/by-ids']);
    expect(route.anchors.map((p) => p?['id']), ids);
  });

  test('an older server is asked point by point, as before', () async {
    final paths = <String>[];
    final route = await fetchRoutePoints(
      _api((request) async {
        final path = request.url.path;
        paths.add(path);
        if (path.endsWith('/by-ids')) {
          return http.Response('{"detail": "Anchor point not found"}', 404);
        }
        if (path.endsWith('/connections')) return http.Response('[]', 200);
        final id = path.split('/').last;
        return http.Response(jsonEncode({'id': id}), 200);
      }),
      ids,
    );
    expect(route.anchors.map((p) => p?['id']), ids);
    expect(paths.where((p) => p.endsWith('/connections')), hasLength(2));
  });
}

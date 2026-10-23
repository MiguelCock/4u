import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:eyes4u/services/route_error.dart';

void main() {
  // An L-shaped route: 50 m north, then 30 m east.
  const start = LatLng(6.2, -75.58);
  LatLng move(LatLng p, double east, double north) => LatLng(
    p.latitude + north / 111195,
    p.longitude + east / 110574 / 0.99415,
  );
  final corner = move(start, 0, 50);
  final end = move(corner, 30, 0);
  final path = [start, move(start, 0, 25), corner, move(corner, 15, 0), end];

  test('distance to the path is the side offset, or to the ends', () {
    expect(distanceToPath(move(start, 4, 20), path), closeTo(4, 0.1));
    expect(distanceToPath(move(start, 0, -6), path), closeTo(6, 0.1));
    expect(distanceToPath(move(corner, 10, -3), path), closeTo(3, 0.1));
  });

  Map<String, dynamic> log({
    required LatLng raw,
    LatLng? corrected,
    List<Map<String, dynamic>> events = const [],
  }) => {
    'gps_lat': raw.latitude,
    'gps_long': raw.longitude,
    'corrected_lat': corrected?.latitude,
    'corrected_long': corrected?.longitude,
    'debug': {'events': events},
  };

  test('summarises raw vs corrected distance from the route', () {
    final logs = [
      log(raw: move(start, 4, 10), corrected: move(start, 1, 10)),
      log(raw: move(start, -6, 30), corrected: move(start, -2, 30)),
      log(raw: move(corner, 10, 2), corrected: move(corner, 10, 3)),
    ];
    final summary = RouteErrorSummary.compute(logs, path);
    expect(summary.raw!.mean, closeTo(4, 0.1));
    expect(summary.corrected!.mean, closeTo(2, 0.1));
    expect(summary.correctedCloserShare, closeTo(2 / 3, 1e-9));
  });

  test('checkpoints are scored against the corner itself', () {
    List<double> pair(LatLng p) => [p.latitude, p.longitude];
    final logs = [
      log(
        raw: start,
        events: [
          {
            'type': 'checkpoint',
            'index': 1,
            'at': '2026-10-23T18:00:00Z',
            'raw': pair(move(corner, 0, -8)),
            'corrected': pair(move(corner, 0, -3)),
          },
          // Tapped by mistake, then undone.
          {
            'type': 'checkpoint',
            'index': 2,
            'at': '2026-10-23T18:00:05Z',
            'raw': pair(start),
          },
          {'type': 'checkpoint_undo', 'index': 2, 'at': '2026-10-23T18:00:06Z'},
        ],
      ),
    ];
    final summary = RouteErrorSummary.compute(logs, path);
    expect(summary.checkpointRaw!.count, 1);
    expect(summary.checkpointRaw!.mean, closeTo(8, 0.1));
    expect(summary.checkpointCorrected!.mean, closeTo(3, 0.1));
  });

  test('no route, no summary', () {
    expect(RouteErrorSummary.compute([log(raw: start)], [start]).isEmpty, true);
  });
}

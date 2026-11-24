// Replays exported walks through DriftWatch, the old rule against the new
// movement-based one (B8, #300). Runs only when WALKS names a folder of
// backend-positioning/scripts/export_session.py exports:
//
//   WALKS=../test_users_comments/walks flutter test test/tools/replay_drift_test.dart
//
// For each walk: the drift cues each rule would say, and for each stretch
// more than 5 m off the line, how long after it began the first cue came.
import 'dart:convert';
import 'dart:io';

import 'package:eyes4u/services/geo_utils.dart';
import 'package:eyes4u/user/drift_watch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

const _endMeters = 6.0; // like TripGuide's _kDriftEndMeters
const _offMeters = 5.0;

class _Result {
  int cues = 0;
  final List<double> delays = []; // seconds from 5 m off to the first cue
  int stretches = 0;
  int unsaid = 0; // stretches over 8 m that got no cue
}

void main() {
  final dir = Platform.environment['WALKS'];
  test(
    'replay drift cues over exported walks',
    () {
      final files =
          Directory(dir!)
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      final totals = {'old': _Result(), 'new': _Result()};
      for (final file in files) {
        final data =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final anchors = {
          for (final a in data['anchors'] as List)
            a['id']: a as Map<String, dynamic>,
        };
        final route = data['route'] as Map<String, dynamic>;
        final ids = [
          route['start_anchor_id'],
          ...(route['waypoint_anchor_ids'] as List? ?? []),
          route['end_anchor_id'],
        ];
        final line = [
          for (final id in ids)
            LatLng(
              (anchors[id]!['latitude'] as num).toDouble(),
              (anchors[id]!['longitude'] as num).toDouble(),
            ),
        ];
        final logs = (data['logs'] as List).cast<Map<String, dynamic>>()
          ..sort(
            (a, b) => (a['timestamp'] as String).compareTo(b['timestamp']),
          );
        final name = file.uri.pathSegments.last;
        final line2 = <String>[];
        for (final rule in ['old', 'new']) {
          final r = _replay(line, logs, movement: rule == 'new');
          final t = totals[rule]!;
          t.cues += r.cues;
          t.delays.addAll(r.delays);
          t.stretches += r.stretches;
          t.unsaid += r.unsaid;
          line2.add('$rule: ${_fmt(r)}');
        }
        // ignore: avoid_print
        print('$name  ${line2.join('   ')}');
      }
      // ignore: avoid_print
      print(
        'TOTAL  old: ${_fmt(totals['old']!)}   new: ${_fmt(totals['new']!)}',
      );
    },
    skip: dir == null ? 'set WALKS to a folder of exported walks' : false,
  );
}

String _fmt(_Result r) {
  final d = [...r.delays]..sort();
  final median = d.isEmpty ? '-' : d[d.length ~/ 2].toStringAsFixed(0);
  return '${r.cues} cues, ${r.stretches} stretches >5 m, '
      'median ${median}s to the cue, ${r.unsaid} over 8 m unsaid';
}

_Result _replay(
  List<LatLng> line,
  List<Map<String, dynamic>> logs, {
  required bool movement,
}) {
  final watch = DriftWatch();
  final r = _Result();
  DateTime? stretchStart;
  var stretchSaid = false;
  var stretchMax = 0.0;
  int? lastSegment;
  void closeStretch() {
    if (stretchStart != null && !stretchSaid && stretchMax > 8) r.unsaid++;
    stretchStart = null;
  }

  for (final log in logs) {
    final debug = (log['debug'] as Map?)?.cast<String, dynamic>() ?? {};
    final lat = (log['corrected_lat'] ?? log['gps_lat']) as num?;
    final lng = (log['corrected_long'] ?? log['gps_long']) as num?;
    if (lat == null || lng == null) continue;
    final here = LatLng(lat.toDouble(), lng.toDouble());
    final now = DateTime.parse(log['timestamp'] as String);
    // The leg: the nearest segment of the route.
    var best = 0;
    SegmentProjection? p;
    for (var i = 0; i + 1 < line.length; i++) {
      final q = projectOntoSegment(here, line[i], line[i + 1]);
      final clamped = q.along.clamp(0, q.length);
      final off = (q.along - clamped).abs() + q.crossTrack.abs();
      final bestOff = p == null
          ? double.infinity
          : (p.along - p.along.clamp(0, p.length)).abs() + p.crossTrack.abs();
      if (off < bestOff) {
        p = q;
        best = i;
      }
    }
    if (p == null) continue;
    if (best != lastSegment) {
      watch.reset();
      closeStretch();
      lastSegment = best;
    }
    if (p.length < _endMeters * 2 ||
        p.along < _endMeters ||
        p.length - p.along < _endMeters) {
      watch.reset();
      closeStretch();
      continue;
    }
    final leg = bearingDegrees(line[best], line[best + 1]);
    double? courseOff;
    var facing = false;
    if (movement) {
      final speed = (debug['gps_speed'] as num?)?.toDouble() ?? 0;
      final course = (debug['gps_course'] as num?)?.toDouble();
      final accuracy = (log['gps_accuracy'] as num?)?.toDouble() ?? 99;
      if (course != null && speed >= 0.7 && accuracy <= 12) {
        courseOff = signedTurn(leg, course);
      }
      final heading = (debug['heading'] as num?)?.toDouble();
      facing =
          debug['heading_reliable'] == true &&
          heading != null &&
          signedTurn(leg, heading).abs() <= 20;
    }
    if (p.crossTrack.abs() > _offMeters) {
      if (stretchStart == null) {
        stretchStart = now;
        stretchSaid = false;
        stretchMax = 0;
      }
      if (p.crossTrack.abs() > stretchMax) stretchMax = p.crossTrack.abs();
    } else {
      closeStretch();
    }
    final side = watch.update(
      p.crossTrack,
      now,
      courseOff: courseOff,
      facingLeg: facing,
    );
    if (side != null) {
      r.cues++;
      if (stretchStart != null && !stretchSaid) {
        r.delays.add(now.difference(stretchStart!).inMilliseconds / 1000);
        stretchSaid = true;
      }
    }
    if (stretchStart != null && stretchSaid == false && r.delays.isEmpty) {}
  }
  closeStretch();
  // Count stretches: every time one opened.
  return r..stretches = _countStretches(line, logs);
}

int _countStretches(List<LatLng> line, List<Map<String, dynamic>> logs) {
  var count = 0;
  var off = false;
  for (final log in logs) {
    final lat = (log['corrected_lat'] ?? log['gps_lat']) as num?;
    final lng = (log['corrected_long'] ?? log['gps_long']) as num?;
    if (lat == null || lng == null) continue;
    final here = LatLng(lat.toDouble(), lng.toDouble());
    var d = double.infinity;
    for (var i = 0; i + 1 < line.length; i++) {
      final q = projectOntoSegment(here, line[i], line[i + 1]);
      final along = q.along.clamp(0, q.length);
      final e = (q.along - along).abs() + q.crossTrack.abs();
      if (e < d) d = e;
    }
    final now = d > _offMeters;
    if (now && !off) count++;
    off = now;
  }
  return count;
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/geo_utils.dart' show routeCorners;
import '../services/location_types.dart' show anchorDisplayName;
import '../services/map_tap.dart';
import '../services/map_tile_config.dart';
import '../services/route_error.dart';

/// Admin: one navigation session on a map, for checking how the GPS
/// correction and guidance behaved. Draws the planned route, the raw GPS
/// path and the corrected path separately; every photo match as a dot with
/// a line to the anchor point it matched (that line is where a pull came
/// from); and every "wrong instruction" report as a red X. Tapping any of
/// them shows what was logged there. Polls while the session is active.
class SessionTrackingScreen extends StatefulWidget {
  final Map<String, dynamic> session;

  const SessionTrackingScreen({super.key, required this.session});

  @override
  State<SessionTrackingScreen> createState() => _SessionTrackingScreenState();
}

class _SessionTrackingScreenState extends State<SessionTrackingScreen> {
  final _navigationApi = NavigationManagementApi();
  final _routeApi = RouteManagementApi();
  final _mapApi = MapManagementApi();
  final _mapController = MapController();

  Timer? _pollTimer;
  bool _stopped = false;
  bool _loading = true;
  bool _fitted = false;
  List<Map<String, dynamic>> _logs = [];
  List<Map<String, dynamic>> _reports = [];
  List<LatLng> _plannedPath = [];
  Map<String, Map<String, dynamic>> _anchors = {};

  bool get _active => widget.session['status'] == 'active';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await Future.wait([_loadPlannedRoute(), _loadAnchors(), _poll()]);
    if (_stopped) return;
    setState(() => _loading = false);
    // A finished session doesn't change any more.
    if (_active) {
      _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
    }
  }

  Future<void> _loadPlannedRoute() async {
    final routeId = widget.session['route_id'] as String?;
    if (routeId == null) return;
    try {
      final route =
          await _routeApi.get('/routes/$routeId') as Map<String, dynamic>;
      final anchorIds = [
        route['start_anchor_id'] as String,
        ...(route['waypoint_anchor_ids'] as List? ?? const []).cast<String>(),
        route['end_anchor_id'] as String,
      ];
      final points = <LatLng>[];
      for (final id in anchorIds) {
        final anchor =
            await _mapApi.get('/anchor-points/$id') as Map<String, dynamic>;
        final position = anchorPosition(anchor);
        if (position != null) points.add(position);
      }
      if (!_stopped) setState(() => _plannedPath = points);
    } on ApiException {
      // The planned route is context; the trails still show without it.
    }
  }

  /// Every anchor point once, to draw where each photo match pointed.
  Future<void> _loadAnchors() async {
    try {
      final anchors = await _mapApi.get('/anchor-points') as List;
      if (_stopped) return;
      setState(() {
        _anchors = {
          for (final a in anchors.cast<Map<String, dynamic>>())
            a['id'] as String: a,
        };
      });
    } on ApiException {
      // Match lines are drawn only for points that loaded.
    }
  }

  Future<void> _poll() async {
    if (_stopped) return;
    final sessionId = widget.session['id'];
    try {
      final results = await Future.wait([
        _navigationApi.get('/logs?session_id=$sessionId'),
        _navigationApi
            .get('/guidance-reports?session_id=$sessionId')
            .catchError((_) => const []),
      ]);
      if (_stopped) return;
      setState(() {
        _logs = (results[0] as List).cast<Map<String, dynamic>>();
        _reports = (results[1] as List).cast<Map<String, dynamic>>();
      });
      _fitOnce();
    } on ApiException {
      // Best-effort polling - a dropped poll just tries again next tick.
    }
  }

  static LatLng? _raw(Map<String, dynamic> log) {
    final lat = (log['gps_lat'] as num?)?.toDouble();
    final lng = (log['gps_long'] as num?)?.toDouble();
    return lat == null || lng == null ? null : LatLng(lat, lng);
  }

  static LatLng? _corrected(Map<String, dynamic> row) {
    final lat = (row['corrected_lat'] as num?)?.toDouble();
    final lng = (row['corrected_long'] as num?)?.toDouble();
    return lat == null || lng == null ? null : LatLng(lat, lng);
  }

  static LatLng? _reportPosition(Map<String, dynamic> report) =>
      _corrected(report) ?? _raw(report);

  void _fitOnce() {
    if (_fitted) return;
    final points = [..._logs.map(_raw).whereType<LatLng>(), ..._plannedPath];
    if (points.length < 2) return;
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_stopped) return;
      try {
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: points,
            padding: const EdgeInsets.all(40),
            maxZoom: 19,
          ),
        );
      } catch (_) {
        _fitted = false; // Map not ready yet; try again on the next poll.
      }
    });
  }

  static Color _confidenceColor(num? score) {
    final s = (score ?? 0).toDouble();
    if (s >= 0.9) return Colors.purple.shade700;
    if (s >= 0.8) return Colors.purple.shade400;
    return Colors.purple.shade200;
  }

  void _onTap(LatLng tapped) {
    final camera = _mapController.camera;
    final report = nearestOnScreen(
      camera: camera,
      tapped: tapped,
      items: _reports,
      positionOf: _reportPosition,
    );
    if (report != null) {
      _showReport(report);
      return;
    }
    final log = nearestOnScreen(
      camera: camera,
      tapped: tapped,
      items: _logs,
      positionOf: (log) => _corrected(log) ?? _raw(log),
      radiusPx: 24,
    );
    if (log != null) _showLog(log);
  }

  String _time(String? iso) {
    final parsed = iso == null ? null : DateTime.tryParse(iso);
    if (parsed == null) return '?';
    final t = parsed.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  String _num(Object? value, {int digits = 1, String unit = ''}) =>
      value is num ? '${value.toStringAsFixed(digits)}$unit' : '—';

  Future<void> _showDetails(String title, List<(String, String)> rows) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 150,
                        child: Text(
                          label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Expanded(child: Text(value)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLog(Map<String, dynamic> log) {
    final l10n = AppLocalizations.of(context)!;
    final debug = (log['debug'] as Map?)?.cast<String, dynamic>() ?? const {};
    final matchId = log['anchor_match_id'] as String?;
    final cues = (debug['cues'] as List? ?? const [])
        .map((c) => (c as Map)['text'])
        .whereType<String>()
        .join(' / ');
    _showDetails(l10n.trackingTickTitle, [
      (l10n.trackingFieldTime, _time(log['timestamp'] as String?)),
      (l10n.trackingFieldGpsAccuracy, _num(log['gps_accuracy'], unit: ' m')),
      (
        l10n.trackingFieldCorrectionError,
        _num(log['correction_error'], unit: ' m'),
      ),
      (
        l10n.trackingFieldMatch,
        matchId == null
            ? l10n.trackingNoMatch
            : '${anchorDisplayName(l10n, _anchors[matchId] ?? {'id': matchId})}'
                  ' (${_num(log['confidence_score'], digits: 2)})',
      ),
      if (cues.isNotEmpty) (l10n.trackingFieldSaid, cues),
      (l10n.trackingFieldTurn, _num(debug['turn'], digits: 0, unit: '°')),
      (l10n.trackingFieldCompass, _num(debug['compass'], digits: 0, unit: '°')),
      (
        l10n.trackingFieldPositionSource,
        debug['position_source']?.toString() ?? '—',
      ),
      if (debug['failure'] != null)
        (l10n.trackingFieldProblem, debug['failure'].toString()),
      if (debug['correction'] != null)
        ('correction', debug['correction'].toString()),
    ]);
  }

  void _showReport(Map<String, dynamic> report) {
    final l10n = AppLocalizations.of(context)!;
    final debug =
        (report['debug'] as Map?)?.cast<String, dynamic>() ?? const {};
    _showDetails(l10n.trackingWrongInstructionTitle, [
      (l10n.trackingFieldTime, _time(report['created_at'] as String?)),
      (l10n.trackingFieldSaid, report['instruction_text'] as String? ?? '—'),
      (l10n.trackingFieldTurn, _num(debug['turn'], digits: 0, unit: '°')),
      (
        l10n.trackingFieldCompass,
        _num(report['compass_heading'], digits: 0, unit: '°'),
      ),
      (
        l10n.trackingFieldPositionSource,
        debug['position_source']?.toString() ?? '—',
      ),
      (l10n.trackingFieldGpsAccuracy, _num(debug['gps_accuracy'], unit: ' m')),
    ]);
  }

  @override
  void dispose() {
    _stopped = true;
    _pollTimer?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  /// For test walks along the route exactly: how far raw GPS and the
  /// correction were from it (see route_error.dart).
  Widget? _errorCard(AppLocalizations l10n) {
    final summary = RouteErrorSummary.compute(_logs, _plannedPath);
    if (summary.isEmpty) return null;
    String m(double v) => v.toStringAsFixed(1);
    Widget row(String label, ErrorStats? stats) => stats == null
        ? const SizedBox.shrink()
        : Text(
            l10n.trackingErrorRow(label, m(stats.mean), m(stats.p90)),
            style: const TextStyle(fontSize: 12),
          );
    final share = summary.correctedCloserShare;
    final titleStyle = Theme.of(context).textTheme.labelLarge;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.trackingErrorTitle, style: titleStyle),
            row(l10n.trackingErrorRaw, summary.raw),
            row(l10n.trackingErrorCorrected, summary.corrected),
            if (share != null)
              Text(
                l10n.trackingErrorCloser((share * 100).round()),
                style: const TextStyle(fontSize: 12),
              ),
            if (summary.checkpointRaw != null) ...[
              const SizedBox(height: 4),
              Text(
                l10n.trackingErrorCheckpointsTitle(
                  summary.checkpointRaw!.count,
                ),
                style: titleStyle,
              ),
              row(l10n.trackingErrorRaw, summary.checkpointRaw),
              row(l10n.trackingErrorCorrected, summary.checkpointCorrected),
            ],
          ],
        ),
      ),
    );
  }

  Widget _legend(AppLocalizations l10n) {
    Widget row(Widget swatch, String label) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 22, child: Center(child: swatch)),
          const SizedBox(width: 6),
          Flexible(child: Text(label, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
    Widget line(Color color) => Container(width: 18, height: 3, color: color);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row(line(Colors.blueGrey), l10n.trackingLegendPlanned),
            row(line(Colors.orange), l10n.trackingLegendRaw),
            row(line(Colors.green), l10n.trackingLegendCorrected),
            row(
              Icon(Icons.circle, size: 10, color: Colors.purple.shade400),
              l10n.trackingLegendMatch,
            ),
            row(
              const Icon(Icons.close, size: 16, color: Colors.red),
              l10n.trackingLegendReport,
            ),
            if (checkpointEvents(_logs).isNotEmpty)
              row(
                const Icon(Icons.flag, size: 16, color: Colors.blue),
                l10n.trackingLegendCheckpoint,
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final raw = _logs.map(_raw).whereType<LatLng>().toList();
    final corrected = _logs.map(_corrected).whereType<LatLng>().toList();
    final matches = [
      for (final log in _logs)
        if (log['anchor_match_id'] != null && _corrected(log) != null) log,
    ];
    final corners = _plannedPath.length > 1
        ? routeCorners(_plannedPath)
        : const <int>[];
    final checkpoints = [
      for (final tap in checkpointEvents(_logs))
        if ((tap['index'] as int) < corners.length)
          _plannedPath[corners[tap['index'] as int]],
    ];
    final errorCard = _errorCard(l10n);
    final center = raw.isNotEmpty
        ? raw.last
        : (_plannedPath.isNotEmpty ? _plannedPath.first : const LatLng(0, 0));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.userSessionsSessionLabel(widget.session['id'])),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: center,
                    initialZoom: 18,
                    onMapReady: _fitOnce,
                    onTap: (_, latLng) => _onTap(latLng),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: kMapTileUrlTemplate,
                      userAgentPackageName: kMapUserAgentPackageName,
                    ),
                    PolylineLayer(
                      polylines: [
                        if (_plannedPath.length > 1)
                          Polyline(
                            points: _plannedPath,
                            strokeWidth: 3,
                            color: Colors.blueGrey,
                          ),
                        if (raw.length > 1)
                          Polyline(
                            points: raw,
                            strokeWidth: 3,
                            color: Colors.orange,
                            pattern: StrokePattern.dashed(segments: [8, 6]),
                          ),
                        if (corrected.length > 1)
                          Polyline(
                            points: corrected,
                            strokeWidth: 4,
                            color: Colors.green,
                          ),
                        // Where each photo match pulled the position from.
                        for (final log in matches)
                          if (anchorPosition(
                                _anchors[log['anchor_match_id']] ?? const {},
                              ) !=
                              null)
                            Polyline(
                              points: [
                                _corrected(log)!,
                                anchorPosition(
                                  _anchors[log['anchor_match_id']]!,
                                )!,
                              ],
                              strokeWidth: 1,
                              color: Colors.purple.withValues(alpha: 0.5),
                            ),
                      ],
                    ),
                    MarkerLayer(
                      markers: [
                        for (final log in matches)
                          Marker(
                            point: _corrected(log)!,
                            width: 14,
                            height: 14,
                            child: Icon(
                              Icons.circle,
                              size: 10,
                              color: _confidenceColor(
                                log['confidence_score'] as num?,
                              ),
                            ),
                          ),
                        for (final point in checkpoints)
                          Marker(
                            point: point,
                            width: 28,
                            height: 28,
                            alignment: Alignment.topCenter,
                            child: const Icon(
                              Icons.flag,
                              color: Colors.blue,
                              size: 24,
                            ),
                          ),
                        for (final report in _reports)
                          if (_reportPosition(report) != null)
                            Marker(
                              point: _reportPosition(report)!,
                              width: 32,
                              height: 32,
                              child: const Icon(
                                Icons.close,
                                color: Colors.red,
                                size: 28,
                              ),
                            ),
                        if (raw.isNotEmpty)
                          Marker(
                            point: corrected.isNotEmpty
                                ? corrected.last
                                : raw.last,
                            width: 40,
                            height: 40,
                            child: const Icon(
                              Icons.my_location,
                              color: Colors.green,
                              size: 26,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                if (errorCard != null)
                  Positioned(left: 8, top: 8, right: 8, child: errorCard),
                Positioned(left: 8, bottom: 8, right: 80, child: _legend(l10n)),
              ],
            ),
    );
  }
}

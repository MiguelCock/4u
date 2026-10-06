import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import '../services/map_tile_config.dart';

/// Admin-only: watches one navigation session live - polls GET /logs every
/// ~4s, filters client-side to this session_id (same "fetch all, filter
/// client-side" convention as everywhere else in this app - there's no
/// session_id query param on that endpoint), and draws the full trail
/// (not just the latest point) through every logged position so far,
/// using the corrected position when a tick has one, else raw GPS.
/// Also overlays the session's planned route (start/end/waypoint anchors)
/// in a second color, so planned-path vs. actual-trail is comparable.
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

  Timer? _pollTimer;
  bool _stopped = false;
  List<LatLng> _trail = [];
  List<LatLng> _plannedPath = [];
  bool _loadingRoute = true;

  @override
  void initState() {
    super.initState();
    _loadPlannedRoute();
    _pollLogs();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _pollLogs());
  }

  Future<void> _loadPlannedRoute() async {
    final routeId = widget.session['route_id'] as String?;
    if (routeId == null) {
      setState(() => _loadingRoute = false);
      return;
    }
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
        final lat = (anchor['latitude'] as num?)?.toDouble();
        final lng = (anchor['longitude'] as num?)?.toDouble();
        if (lat != null && lng != null) points.add(LatLng(lat, lng));
      }
      if (!_stopped) setState(() => _plannedPath = points);
    } on ApiException {
      // The planned-path overlay is a nice-to-have - a missing/deleted
      // route shouldn't block watching the live trail.
    } finally {
      if (!_stopped) setState(() => _loadingRoute = false);
    }
  }

  Future<void> _pollLogs() async {
    if (_stopped) return;
    try {
      final result = await _navigationApi.get('/logs');
      if (result is! List || _stopped) return;
      final sessionId = widget.session['id'];
      final logs =
          result
              .cast<Map<String, dynamic>>()
              .where((log) => log['session_id'] == sessionId)
              .toList()
            ..sort(
              (a, b) => (a['timestamp'] as String).compareTo(
                b['timestamp'] as String,
              ),
            );
      final trail = <LatLng>[];
      for (final log in logs) {
        final lat =
            (log['corrected_lat'] as num?)?.toDouble() ??
            (log['gps_lat'] as num?)?.toDouble();
        final lng =
            (log['corrected_long'] as num?)?.toDouble() ??
            (log['gps_long'] as num?)?.toDouble();
        if (lat != null && lng != null) trail.add(LatLng(lat, lng));
      }
      if (!_stopped) setState(() => _trail = trail);
    } on ApiException {
      // Best-effort polling - a dropped poll just tries again next tick.
    }
  }

  @override
  void dispose() {
    _stopped = true;
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final center = _trail.isNotEmpty
        ? _trail.last
        : (_plannedPath.isNotEmpty ? _plannedPath.first : const LatLng(0, 0));
    return Scaffold(
      appBar: AppBar(title: Text('Session ${widget.session['id']}')),
      body: _loadingRoute
          ? const Center(child: CircularProgressIndicator())
          : FlutterMap(
              options: MapOptions(initialCenter: center, initialZoom: 17),
              children: [
                TileLayer(
                  urlTemplate: kMapTileUrlTemplate,
                  userAgentPackageName: kMapUserAgentPackageName,
                ),
                if (_plannedPath.length > 1)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _plannedPath,
                        strokeWidth: 3,
                        color: Colors.blueGrey,
                      ),
                    ],
                  ),
                if (_trail.length > 1)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _trail,
                        strokeWidth: 4,
                        color: Colors.green,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    if (_trail.isNotEmpty)
                      Marker(
                        point: _trail.last,
                        width: 60,
                        height: 60,
                        child: const Icon(
                          Icons.my_location,
                          color: Colors.green,
                          size: 32,
                        ),
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}

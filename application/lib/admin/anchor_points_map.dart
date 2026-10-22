import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../map.dart' show locationPinMarker;
import '../services/map_tap.dart';
import '../services/map_tile_config.dart';

/// Map view of the admin Anchor points tab: the same filtered points as the
/// list, coloured by status, with the connections between them drawn
/// faintly. A tap near a point reports it ([onPointTapped]). While a point
/// is being moved ([movingPointId] set), a tap reports the new position
/// instead ([onMoveTargetTapped]) and [moveTarget] is shown as a pin whose
/// tip sits exactly on that spot.
class AnchorPointsMap extends StatefulWidget {
  final List<Map<String, dynamic>> points;
  final List<Map<String, dynamic>> connections;
  final String? movingPointId;
  final LatLng? moveTarget;
  final ValueChanged<Map<String, dynamic>> onPointTapped;
  final ValueChanged<LatLng> onMoveTargetTapped;

  const AnchorPointsMap({
    super.key,
    required this.points,
    required this.connections,
    required this.onPointTapped,
    required this.onMoveTargetTapped,
    this.movingPointId,
    this.moveTarget,
  });

  @override
  State<AnchorPointsMap> createState() => _AnchorPointsMapState();
}

class _AnchorPointsMapState extends State<AnchorPointsMap> {
  final _controller = MapController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<LatLng> get _positions =>
      widget.points.map(anchorPosition).whereType<LatLng>().toList();

  void _fitToPoints() {
    final positions = _positions;
    if (positions.isEmpty) return;
    if (positions.length == 1) {
      _controller.move(positions.first, 19);
      return;
    }
    _controller.fitCamera(
      CameraFit.coordinates(
        coordinates: positions,
        padding: const EdgeInsets.all(48),
        maxZoom: 19,
      ),
    );
  }

  static Color _statusColor(String? status) => switch (status) {
    'verified' => Colors.green,
    'rejected' => Colors.red,
    _ => Colors.grey,
  };

  void _onTap(LatLng tapped) {
    if (widget.movingPointId != null) {
      widget.onMoveTargetTapped(tapped);
      return;
    }
    final point = nearestOnScreen(
      camera: _controller.camera,
      tapped: tapped,
      items: widget.points,
      positionOf: anchorPosition,
    );
    if (point != null) widget.onPointTapped(point);
  }

  @override
  Widget build(BuildContext context) {
    final byId = {
      for (final p in widget.points)
        if (anchorPosition(p) != null) p['id'] as String: anchorPosition(p)!,
    };
    final lines = [
      for (final c in widget.connections)
        if (byId.containsKey(c['anchor_point_a_id']) &&
            byId.containsKey(c['anchor_point_b_id']))
          Polyline(
            points: [
              byId[c['anchor_point_a_id']]!,
              byId[c['anchor_point_b_id']]!,
            ],
            color: Colors.teal.withValues(alpha: 0.5),
            strokeWidth: 2,
          ),
    ];
    final positions = _positions;
    final moveTarget = widget.moveTarget;

    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: positions.isNotEmpty
            ? positions.first
            : const LatLng(6.2, -75.58),
        initialZoom: 18,
        // No double-tap zoom: it made every single tap wait for a second.
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.doubleTapZoom,
        ),
        onMapReady: _fitToPoints,
        onTap: (_, latLng) => _onTap(latLng),
      ),
      children: [
        TileLayer(
          urlTemplate: kMapTileUrlTemplate,
          userAgentPackageName: kMapUserAgentPackageName,
        ),
        PolylineLayer(polylines: lines),
        MarkerLayer(
          markers: [
            for (final point in widget.points)
              if (anchorPosition(point) != null)
                Marker(
                  point: anchorPosition(point)!,
                  width: 40,
                  height: 40,
                  child: Icon(
                    point['id'] == widget.movingPointId
                        ? Icons.radio_button_checked
                        : Icons.circle,
                    color: point['id'] == widget.movingPointId
                        ? Colors.blue
                        : _statusColor(point['status'] as String?),
                    size: point['id'] == widget.movingPointId ? 30 : 18,
                  ),
                ),
            if (moveTarget != null) locationPinMarker(moveTarget, Colors.blue),
          ],
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../map.dart' show locationPinMarker;
import '../services/floor_view.dart';
import '../services/map_tap.dart';
import '../services/map_tile_config.dart';
import '../widgets/floor_selector.dart';

/// Map view of the admin Anchor points tab: the same filtered points as the
/// list, coloured by status, with the connections between them drawn
/// faintly. A tap near a point reports it ([onPointTapped]). While a point
/// is being moved ([movingPointId] set), a tap reports the new position
/// instead ([onMoveTargetTapped]) and [moveTarget] is shown as a pin whose
/// tip sits exactly on that spot. One floor shows at a time (FloorSelector),
/// with the floors directly above and below as small triangles that can be
/// tapped too; the point being moved always shows.
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
  int? _floor;
  bool _onlySelectedFloor = false;

  @override
  void initState() {
    super.initState();
    loadOnlySelectedFloor().then((value) {
      if (mounted) setState(() => _onlySelectedFloor = value);
    });
  }

  @override
  void didUpdateWidget(AnchorPointsMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Starting a move shows the floor of the point being moved.
    final moving = widget.movingPointId;
    if (moving != null && moving != oldWidget.movingPointId) {
      for (final point in widget.points) {
        if (point['id'] == moving) _floor = pointFloor(point);
      }
    }
  }

  int get _selectedFloor {
    final floors = floorsOf(widget.points);
    return floorInRange(_floor ?? openingFloor(floors) ?? 0, floors) ?? 0;
  }

  FloorRelation _relation(Map<String, dynamic> point) =>
      floorRelation(point, _selectedFloor, onlySelected: _onlySelectedFloor);

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
    // The selected floor first: stairs on two floors are on top of each other.
    Map<String, dynamic>? nearest(bool Function(FloorRelation) showing) =>
        nearestOnScreen(
          camera: _controller.camera,
          tapped: tapped,
          items: widget.points.where((p) => showing(_relation(p))),
          positionOf: anchorPosition,
        );
    final point =
        nearest((r) => r == FloorRelation.current) ??
        nearest((r) => r != FloorRelation.hidden);
    if (point != null) widget.onPointTapped(point);
  }

  @override
  Widget build(BuildContext context) {
    final byId = {
      for (final p in widget.points)
        if (anchorPosition(p) != null) p['id'] as String: p,
    };
    final floor = _selectedFloor;
    final lines = <Polyline>[];
    for (final c in widget.connections) {
      final a = byId[c['anchor_point_a_id']];
      final b = byId[c['anchor_point_b_id']];
      if (a == null || b == null) continue;
      if (!floorShowsConnection(
        a,
        b,
        floor,
        onlySelected: _onlySelectedFloor,
      )) {
        continue;
      }
      lines.add(
        Polyline(
          points: [anchorPosition(a)!, anchorPosition(b)!],
          color: Colors.teal.withValues(alpha: 0.5),
          strokeWidth: 2,
          pattern: pointFloor(a) == pointFloor(b)
              ? const StrokePattern.solid()
              : StrokePattern.dashed(segments: const [6, 4]),
        ),
      );
    }
    final positions = _positions;
    final moveTarget = widget.moveTarget;

    return Stack(
      children: [
        _map(lines, positions, moveTarget),
        Positioned(
          right: 8,
          top: 8,
          child: FloorSelector(
            floors: floorsOf(widget.points),
            selected: floor,
            onlySelected: _onlySelectedFloor,
            onFloorChanged: (value) => setState(() => _floor = value),
            onOnlySelectedChanged: (value) {
              setState(() => _onlySelectedFloor = value);
              saveOnlySelectedFloor(value);
            },
          ),
        ),
      ],
    );
  }

  Widget _map(
    List<Polyline> lines,
    List<LatLng> positions,
    LatLng? moveTarget,
  ) {
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
            // The other floors first, so the selected one is drawn on top.
            for (final point in widget.points)
              if (anchorPosition(point) != null &&
                  point['id'] != widget.movingPointId &&
                  (_relation(point) == FloorRelation.above ||
                      _relation(point) == FloorRelation.below))
                floorPointMarker(anchorPosition(point)!, _relation(point)),
            for (final point in widget.points)
              if (anchorPosition(point) != null &&
                  (_relation(point) == FloorRelation.current ||
                      point['id'] == widget.movingPointId))
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

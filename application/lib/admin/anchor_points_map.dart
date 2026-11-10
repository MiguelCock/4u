import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/floor_view.dart';
import '../services/map_tap.dart';
import '../widgets/admin_map/admin_map.dart';
import '../widgets/admin_map/layers.dart';

/// Map view of the admin Anchor points tab: the same filtered points as the
/// list, coloured by status, with the connections between them drawn
/// faintly. A tap near a point reports it ([onPointTapped]). While a point
/// is being moved ([movingPointId] set), a tap reports the new position
/// instead ([onMoveTargetTapped]) and [moveTarget] is shown as a pin whose
/// tip sits exactly on that spot. One floor shows at a time, with the floors
/// directly above and below as small triangles that can be tapped too; the
/// point being moved always shows. Built on [AdminMap].
class AnchorPointsMap extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final moving = movingPointId;
    final target = moveTarget;
    int? movingFloor;
    for (final point in points) {
      if (moving != null && point['id'] == moving) {
        movingFloor = pointFloor(point);
      }
    }
    return AdminMap(
      floors: floorsOf(points),
      fitTo: points.map(anchorPosition).whereType<LatLng>().toList(),
      mode: moving == null ? AdminMapMode.browse : AdminMapMode.move,
      // Starting a move shows the floor of the point being moved.
      focusFloor: movingFloor,
      // Below the "tap the new position" banner while moving a point.
      controlsTop: moving == null ? 8 : 72,
      layers: [
        ConnectionsLayer(points: points, connections: connections),
        PointsLayer(points: points, movingId: moving),
        if (target != null) PinLayer(position: target),
      ],
      onHit: (hit) => switch (hit) {
        PointHit(:final point) => onPointTapped(point),
        _ => null,
      },
      onTapPosition: moving == null ? null : onMoveTargetTapped,
    );
  }
}

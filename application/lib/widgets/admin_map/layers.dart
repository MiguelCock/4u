import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../map.dart' show locationPinMarker;
import '../../services/floor_view.dart';
import '../../services/map_tap.dart';
import '../floor_selector.dart';
import 'admin_map.dart';

/// The colour of a point's review status.
Color anchorStatusColor(String? status) => switch (status) {
  'verified' => Colors.green,
  'rejected' => Colors.red,
  _ => Colors.grey,
};

/// Anchor points: the selected floor as dots coloured by status, the floors
/// directly above and below as ▲/▼, and the point being moved ([movingId]) on
/// any floor. The dots are one [CircleLayer], drawn on one canvas, so a few
/// hundred of them don't mean a few hundred widgets.
class PointsLayer extends AdminMapLayer {
  final List<Map<String, dynamic>> points;
  final String? movingId;

  /// The first point of a connection being made: a blue ring, on any floor.
  final String? selectedId;
  @override
  final double minZoom;

  const PointsLayer({
    required this.points,
    this.movingId,
    this.selectedId,
    this.minZoom = 0,
  });

  @override
  bool get usesFloors => true;

  @override
  List<Widget> build(AdminMapView view) {
    final circles = <CircleMarker>[];
    final markers = <Marker>[];
    Marker? moving;
    Marker? selected;
    for (final point in points) {
      final position = anchorPosition(point);
      if (position == null) continue;
      if (point['id'] == selectedId) {
        selected = Marker(
          point: position,
          width: 40,
          height: 40,
          child: const Icon(
            Icons.radio_button_checked,
            color: Colors.blue,
            size: 30,
          ),
        );
        continue;
      }
      if (point['id'] == movingId) {
        moving = Marker(
          point: position,
          width: 40,
          height: 40,
          child: const Icon(
            Icons.radio_button_checked,
            color: Colors.blue,
            size: 30,
          ),
        );
        continue;
      }
      switch (view.relation(point)) {
        case FloorRelation.current:
          // The size of the 18 px circle icon this replaced.
          circles.add(
            CircleMarker(
              point: position,
              radius: 7.5,
              color: anchorStatusColor(point['status'] as String?),
            ),
          );
        case FloorRelation.above || FloorRelation.below:
          markers.add(floorPointMarker(position, view.relation(point)));
        case FloorRelation.hidden:
          break;
      }
    }
    return [
      // The other floors first, so the selected one is drawn on top.
      MarkerLayer(markers: markers),
      CircleLayer(circles: circles),
      if (moving != null || selected != null)
        MarkerLayer(markers: [?moving, ?selected]),
    ];
  }

  @override
  AdminMapHit? hitTest(MapCamera camera, LatLng tapped, AdminMapView view) {
    // The selected floor first: stairs on two floors are on top of each other.
    Map<String, dynamic>? nearest(bool Function(FloorRelation) showing) =>
        nearestOnScreen(
          camera: camera,
          tapped: tapped,
          items: points.where((p) => showing(view.relation(p))),
          positionOf: anchorPosition,
        );
    final point =
        nearest((r) => r == FloorRelation.current) ??
        nearest((r) => r != FloorRelation.hidden) ??
        // The selected point shows on any floor, so it can be tapped there.
        nearestOnScreen(
          camera: camera,
          tapped: tapped,
          items: points.where((p) => p['id'] == selectedId),
          positionOf: anchorPosition,
        );
    return point == null ? null : PointHit(point);
  }
}

/// Connections between [points], drawn when one end is on the selected floor
/// and the other is shown; dashed across floors.
class ConnectionsLayer extends AdminMapLayer {
  final List<Map<String, dynamic>> points;
  final List<Map<String, dynamic>> connections;
  @override
  final double minZoom;

  /// Strong lines while connecting; faint ones otherwise, under the points.
  final bool prominent;

  const ConnectionsLayer({
    required this.points,
    required this.connections,
    this.minZoom = 0,
    this.prominent = false,
  });

  /// The two ends of each connection drawn, by connection.
  Iterable<(Map<String, dynamic>, LatLng, LatLng)> _drawn(
    AdminMapView view,
  ) sync* {
    final byId = {
      for (final p in points)
        if (anchorPosition(p) != null) p['id'] as String: p,
    };
    for (final c in connections) {
      final a = byId[c['anchor_point_a_id']];
      final b = byId[c['anchor_point_b_id']];
      if (a == null || b == null) continue;
      if (!floorShowsConnection(
        a,
        b,
        view.floor,
        onlySelected: view.onlySelected,
      )) {
        continue;
      }
      yield (c, anchorPosition(a)!, anchorPosition(b)!);
    }
  }

  @override
  AdminMapHit? hitTest(MapCamera camera, LatLng tapped, AdminMapView view) {
    final hit = nearestLineOnScreen(
      camera: camera,
      tapped: tapped,
      // A line still being saved has no row to show yet.
      items: _drawn(view).where((d) => d.$1['pending'] != true),
      endsOf: (d) => (d.$2, d.$3),
    );
    return hit == null ? null : ConnectionHit(hit.$1);
  }

  @override
  bool get usesFloors => true;

  @override
  List<Widget> build(AdminMapView view) {
    final byId = {
      for (final p in points)
        if (anchorPosition(p) != null) p['id'] as String: p,
    };
    final lines = <Polyline>[];
    for (final (c, a, b) in _drawn(view)) {
      final pending = c['pending'] == true;
      final sameFloor =
          pointFloor(byId[c['anchor_point_a_id']]!) ==
          pointFloor(byId[c['anchor_point_b_id']]!);
      lines.add(
        Polyline(
          points: [a, b],
          color: pending
              ? Colors.grey
              : prominent
              ? Colors.green
              : Colors.teal.withValues(alpha: 0.5),
          strokeWidth: prominent && !pending ? 3 : 2,
          pattern: pending
              ? const StrokePattern.dotted()
              : sameFloor
              ? const StrokePattern.solid()
              : StrokePattern.dashed(
                  segments: prominent ? const [8, 6] : const [6, 4],
                ),
        ),
      );
    }
    return [PolylineLayer(polylines: lines)];
  }
}

/// A pin whose tip is on [position]: a picked spot, or where a point moves.
class PinLayer extends AdminMapLayer {
  final LatLng position;
  final Color color;

  const PinLayer({required this.position, this.color = Colors.blue});

  @override
  List<Widget> build(AdminMapView view) => [
    MarkerLayer(markers: [locationPinMarker(position, color)]),
  ];
}

/// A university's flag with its building count: the location picker's, and
/// the admin map's far view. Greyed when inactive.
Marker placeMarker(LatLng position, int buildingCount, {bool active = true}) =>
    _countedMarker(
      position,
      Icons.flag,
      active ? Colors.purple : Colors.grey,
      buildingCount,
    );

/// A building with its point count. Greyed when inactive.
Marker buildingMarker(LatLng position, int pointCount, {bool active = true}) =>
    _countedMarker(
      position,
      Icons.apartment,
      active ? Colors.orange : Colors.grey,
      pointCount,
    );

Marker _countedMarker(LatLng position, IconData icon, Color color, int count) =>
    Marker(
      point: position,
      width: 60,
      height: 60,
      // Centred, so the icon (not the Stack's top-left corner) sits on the
      // coordinate.
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Icon(icon, color: color, size: 30),
          if (count > 0)
            // On the top-right corner of the centred 30px icon.
            Positioned(
              right: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                constraints: const BoxConstraints(minWidth: 16),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white, width: 1),
                ),
                child: Text(
                  '$count',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

/// Universities, each with its building count, below [maxZoom].
class PlacesLayer extends AdminMapLayer {
  final List<Map<String, dynamic>> places;
  final Map<String, int> buildingCounts;
  @override
  final double maxZoom;

  const PlacesLayer({
    required this.places,
    required this.buildingCounts,
    this.maxZoom = kMapBuildingsZoom,
  });

  @override
  List<Widget> build(AdminMapView view) => [
    MarkerLayer(
      markers: [
        for (final place in places)
          if (anchorPosition(place) case final position?)
            placeMarker(
              position,
              buildingCounts[place['id']] ?? 0,
              active: place['is_active'] != false,
            ),
      ],
    ),
  ];

  @override
  AdminMapHit? hitTest(MapCamera camera, LatLng tapped, AdminMapView view) {
    final place = nearestOnScreen(
      camera: camera,
      tapped: tapped,
      items: places,
      positionOf: anchorPosition,
    );
    return place == null ? null : PlaceHit(place);
  }
}

/// Buildings, each with its point count, from [minZoom] up to [maxZoom].
class BuildingsLayer extends AdminMapLayer {
  final List<Map<String, dynamic>> buildings;
  final Map<String, int> pointCounts;
  @override
  final double minZoom;
  @override
  final double maxZoom;

  const BuildingsLayer({
    required this.buildings,
    required this.pointCounts,
    this.minZoom = kMapBuildingsZoom,
    this.maxZoom = kMapPointsZoom,
  });

  @override
  List<Widget> build(AdminMapView view) => [
    MarkerLayer(
      markers: [
        for (final building in buildings)
          if (anchorPosition(building) case final position?)
            buildingMarker(
              position,
              pointCounts[building['id']] ?? 0,
              active: building['is_active'] != false,
            ),
      ],
    ),
  ];

  @override
  AdminMapHit? hitTest(MapCamera camera, LatLng tapped, AdminMapView view) {
    final building = nearestOnScreen(
      camera: camera,
      tapped: tapped,
      items: buildings,
      positionOf: anchorPosition,
    );
    return building == null ? null : BuildingHit(building);
  }
}

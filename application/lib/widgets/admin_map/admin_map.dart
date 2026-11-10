import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../services/floor_view.dart';
import '../../services/map_tile_config.dart';
import '../floor_selector.dart';

/// The floor a map is showing, which every layer draws against.
class AdminMapView {
  final int floor;
  final bool onlySelected;

  const AdminMapView({required this.floor, required this.onlySelected});

  FloorRelation relation(Map<String, dynamic> point) =>
      floorRelation(point, floor, onlySelected: onlySelected);
}

/// What a tap on an [AdminMap] found. More kinds (universities, buildings,
/// connections) come with the layers that draw them.
sealed class AdminMapHit {
  const AdminMapHit();
}

class PointHit extends AdminMapHit {
  final Map<String, dynamic> point;
  const PointHit(this.point);
}

/// One kind of thing on an [AdminMap]: what it draws, and what a tap hits.
abstract class AdminMapLayer {
  const AdminMapLayer();

  /// flutter_map layers, bottom first.
  List<Widget> build(AdminMapView view);

  /// What a tap at [tapped] hit, or null. Layers are asked top first.
  AdminMapHit? hitTest(MapCamera camera, LatLng tapped, AdminMapView view) =>
      null;
}

/// How taps are read. In [pick] and [move] every tap is a position, even on
/// a point; otherwise a tap is checked against the layers first.
enum AdminMapMode { browse, pick, move, connect }

/// The admin's map: tiles, no double-tap zoom, the opening fit, the floor
/// shown (with [FloorSelector] and the remembered "only this floor") and taps.
/// What's drawn comes from [layers]. See `docs/decisions/c1-admin-map.md`.
class AdminMap extends StatefulWidget {
  final List<AdminMapLayer> layers;

  /// The floors the selector offers, lowest first.
  final List<int> floors;

  /// Shown from the start: two or more are fitted, one is centred.
  final List<LatLng> fitTo;

  final AdminMapMode mode;

  /// When it changes to a floor, the map shows that floor (the point being
  /// moved, for instance).
  final int? focusFloor;

  final ValueChanged<AdminMapHit>? onHit;

  /// Every tap in [AdminMapMode.pick] and [AdminMapMode.move], else a tap that
  /// hit nothing.
  final ValueChanged<LatLng>? onTapPosition;

  /// Room above the floor selector, for a banner over the map.
  final double controlsTop;

  /// Off in tests, which have no network for tiles.
  @visibleForTesting
  final bool showTiles;

  const AdminMap({
    super.key,
    required this.layers,
    required this.floors,
    required this.fitTo,
    this.mode = AdminMapMode.browse,
    this.focusFloor,
    this.onHit,
    this.onTapPosition,
    this.controlsTop = 8,
    this.showTiles = true,
  });

  @override
  State<AdminMap> createState() => _AdminMapState();
}

class _AdminMapState extends State<AdminMap> {
  final _controller = MapController();
  int? _floor;
  bool _onlySelected = false;

  @override
  void initState() {
    super.initState();
    _floor = widget.focusFloor;
    loadOnlySelectedFloor().then((value) {
      if (mounted) setState(() => _onlySelected = value);
    });
  }

  @override
  void didUpdateWidget(AdminMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final focus = widget.focusFloor;
    if (focus != null && focus != oldWidget.focusFloor) _floor = focus;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _selectedFloor =>
      floorInRange(_floor ?? openingFloor(widget.floors) ?? 0, widget.floors) ??
      0;

  AdminMapView get _view =>
      AdminMapView(floor: _selectedFloor, onlySelected: _onlySelected);

  /// Frames [AdminMap.fitTo] from the start. Moving the camera once the map
  /// was ready cancelled the tiles it had just asked for and left the
  /// background empty.
  CameraFit? get _initialFit {
    if (widget.fitTo.length < 2) return null;
    return CameraFit.coordinates(
      coordinates: widget.fitTo,
      padding: const EdgeInsets.all(48),
      maxZoom: 19,
    );
  }

  void _onTap(LatLng tapped) {
    if (widget.mode == AdminMapMode.pick || widget.mode == AdminMapMode.move) {
      widget.onTapPosition?.call(tapped);
      return;
    }
    final view = _view;
    for (final layer in widget.layers.reversed) {
      final hit = layer.hitTest(_controller.camera, tapped, view);
      if (hit != null) {
        widget.onHit?.call(hit);
        return;
      }
    }
    widget.onTapPosition?.call(tapped);
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    final fitTo = widget.fitTo;
    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: fitTo.isNotEmpty
                ? fitTo.first
                : const LatLng(6.2, -75.58),
            initialZoom: fitTo.length == 1 ? 19 : 18,
            initialCameraFit: _initialFit,
            // No double-tap zoom: it made every single tap wait for a second.
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.doubleTapZoom,
            ),
            onTap: (_, latLng) => _onTap(latLng),
          ),
          children: [
            if (widget.showTiles)
              TileLayer(
                urlTemplate: kMapTileUrlTemplate,
                userAgentPackageName: kMapUserAgentPackageName,
              ),
            for (final layer in widget.layers) ...layer.build(view),
          ],
        ),
        Positioned(
          right: 8,
          top: widget.controlsTop,
          child: FloorSelector(
            floors: widget.floors,
            selected: view.floor,
            onlySelected: _onlySelected,
            onFloorChanged: (value) => setState(() => _floor = value),
            onOnlySelectedChanged: (value) {
              setState(() => _onlySelected = value);
              saveOnlySelectedFloor(value);
            },
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../services/floor_view.dart';
import '../../services/map_tile_config.dart';
import '../floor_selector.dart';

/// Below this zoom the admin map shows universities; from it, buildings.
const double kMapBuildingsZoom = 15;

/// From this zoom the admin map shows points and connections.
const double kMapPointsZoom = 17;

/// The floor a map is showing, which every layer draws against.
class AdminMapView {
  final int floor;
  final bool onlySelected;

  const AdminMapView({required this.floor, required this.onlySelected});

  FloorRelation relation(Map<String, dynamic> point) =>
      floorRelation(point, floor, onlySelected: onlySelected);
}

/// What a tap on an [AdminMap] found. Connections come with C3.
sealed class AdminMapHit {
  const AdminMapHit();
}

class PlaceHit extends AdminMapHit {
  final Map<String, dynamic> place;
  const PlaceHit(this.place);
}

class BuildingHit extends AdminMapHit {
  final Map<String, dynamic> building;
  const BuildingHit(this.building);
}

class PointHit extends AdminMapHit {
  final Map<String, dynamic> point;
  const PointHit(this.point);
}

/// One kind of thing on an [AdminMap]: what it draws, and what a tap hits.
abstract class AdminMapLayer {
  const AdminMapLayer();

  /// Drawn and tappable from [minZoom] up to, not including, [maxZoom].
  double get minZoom => 0;
  double get maxZoom => double.infinity;

  /// Whether it draws by floor, which shows the floor selector.
  bool get usesFloors => false;

  bool visibleAt(double zoom) => zoom >= minZoom && zoom < maxZoom;

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
/// What's drawn comes from [layers], each from its own zoom up. See
/// `docs/decisions/c1-admin-map.md`.
class AdminMap extends StatefulWidget {
  final List<AdminMapLayer> layers;

  /// The floors the selector offers, lowest first.
  final List<int> floors;

  /// Shown from the start: two or more are fitted, one is centred.
  final List<LatLng> fitTo;

  /// The zoom range the opening fit stays in.
  final double fitMinZoom;
  final double fitMaxZoom;

  final AdminMapMode mode;

  /// When it changes to a floor, the map shows that floor (the point being
  /// moved, for instance).
  final int? focusFloor;

  final ValueChanged<AdminMapHit>? onHit;

  /// Every tap in [AdminMapMode.pick] and [AdminMapMode.move], else a tap that
  /// hit nothing.
  final ValueChanged<LatLng>? onTapPosition;

  /// A mouse over something (null: over nothing), and where on the map.
  final void Function(AdminMapHit? hit, Offset at)? onHover;

  /// For a screen that moves the camera itself; it can, once [onReady].
  final MapController? controller;
  final VoidCallback? onReady;

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
    this.fitMinZoom = 0,
    this.fitMaxZoom = 19,
    this.mode = AdminMapMode.browse,
    this.focusFloor,
    this.onHit,
    this.onTapPosition,
    this.onHover,
    this.controller,
    this.onReady,
    this.controlsTop = 8,
    this.showTiles = true,
  });

  @override
  State<AdminMap> createState() => _AdminMapState();
}

class _AdminMapState extends State<AdminMap> {
  late final MapController _controller = widget.controller ?? MapController();
  int? _floor;
  bool _onlySelected = false;

  /// The zoom the layers were last chosen for. Rebuilt only when a layer
  /// appears or disappears, not on every frame of a zoom.
  double? _zoom;

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
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  double get _initialZoom => widget.fitTo.length == 1
      ? 19.clamp(widget.fitMinZoom, widget.fitMaxZoom).toDouble()
      : 18.clamp(widget.fitMinZoom, widget.fitMaxZoom).toDouble();

  List<AdminMapLayer> get _visible {
    final zoom = _zoom ?? _initialZoom;
    return [
      for (final layer in widget.layers)
        if (layer.visibleAt(zoom)) layer,
    ];
  }

  void _zoomChanged(double zoom) {
    final now = [for (final l in widget.layers) l.visibleAt(zoom)];
    final before = [for (final l in widget.layers) l.visibleAt(_zoom ?? -1)];
    if (_zoom != null && _listEquals(now, before)) return;
    // Called while the map is laid out, too: set it after this frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _zoom = zoom);
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  static bool _listEquals(List<bool> a, List<bool> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
      minZoom: widget.fitMinZoom,
      maxZoom: widget.fitMaxZoom,
    );
  }

  AdminMapHit? _hitAt(LatLng position) {
    final view = _view;
    for (final layer in _visible.reversed) {
      final hit = layer.hitTest(_controller.camera, position, view);
      if (hit != null) return hit;
    }
    return null;
  }

  void _onTap(LatLng tapped) {
    if (widget.mode == AdminMapMode.pick || widget.mode == AdminMapMode.move) {
      widget.onTapPosition?.call(tapped);
      return;
    }
    final hit = _hitAt(tapped);
    if (hit != null) {
      widget.onHit?.call(hit);
    } else {
      widget.onTapPosition?.call(tapped);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    final visible = _visible;
    final fitTo = widget.fitTo;
    final onHover = widget.onHover;
    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: fitTo.isNotEmpty
                ? fitTo.first
                : const LatLng(6.2, -75.58),
            initialZoom: _initialZoom,
            initialCameraFit: _initialFit,
            // No double-tap zoom: it made every single tap wait for a second.
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.doubleTapZoom,
            ),
            onTap: (_, latLng) => _onTap(latLng),
            onPointerHover: onHover == null
                ? null
                : (event, latLng) =>
                      onHover(_hitAt(latLng), event.localPosition),
            onPositionChanged: (camera, _) => _zoomChanged(camera.zoom),
            onMapReady: () {
              _zoomChanged(_controller.camera.zoom);
              widget.onReady?.call();
            },
          ),
          children: [
            if (widget.showTiles)
              TileLayer(
                urlTemplate: kMapTileUrlTemplate,
                userAgentPackageName: kMapUserAgentPackageName,
              ),
            for (final layer in visible) ...layer.build(view),
          ],
        ),
        if (visible.any((layer) => layer.usesFloors))
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

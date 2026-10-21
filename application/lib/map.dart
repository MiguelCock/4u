import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'services/location_service.dart';
import 'services/map_tile_config.dart';

/// A map pin whose *tip* sits exactly on [point]. A plain centred
/// `Icons.location_pin` marker puts the glyph's middle on the point, which
/// draws the tip ~17px south of it, so the pin never lined up with route
/// lines or anchor dots, and a point picked by aiming the tip was saved
/// north of where the admin meant. The glyph's tip is at y=22 of its 24-unit
/// box, so it's 36.7px down a 40px icon.
Marker locationPinMarker(LatLng point, Color color) {
  const size = 40.0;
  return Marker(
    point: point,
    width: size,
    height: size,
    alignment: Marker.computePixelAlignment(
      width: size,
      height: size,
      left: size / 2,
      top: size * 22 / 24,
    ),
    child: Icon(Icons.location_pin, color: color, size: size),
  );
}

class SimpleMapWidget extends StatefulWidget {
  /// Extra markers layered on top of the live-GPS marker below, e.g. a
  /// corrected-position pin from NavigationScreen. Empty for every other
  /// call site, so this is purely additive.
  final List<Marker> extraMarkers;

  /// The planned route's anchor points, in order, drawn as a line under
  /// the markers - e.g. NavigationScreen's turn-by-turn guidance line.
  /// Empty for every other call site, so this is purely additive too.
  final List<LatLng> plannedPath;

  /// Called on a tap anywhere on the map (not a drag/zoom gesture).
  final VoidCallback? onTap;

  const SimpleMapWidget({
    super.key,
    this.extraMarkers = const [],
    this.plannedPath = const [],
    this.onTap,
  });

  @override
  State<SimpleMapWidget> createState() => _SimpleMapWidgetState();
}

class _SimpleMapWidgetState extends State<SimpleMapWidget> {
  final _service = LocationService();
  final _mapController = MapController();
  StreamSubscription<Position>? _subscription;
  late LatLng _position;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _position = _service.lastPosition != null
        ? LatLng(
            _service.lastPosition!.latitude,
            _service.lastPosition!.longitude,
          )
        : const LatLng(0, 0);

    _subscription = _service.positionStream.listen(
      (pos) => mounted
          ? setState(() => _position = LatLng(pos.latitude, pos.longitude))
          : null,
    );
  }

  @override
  void didUpdateWidget(SimpleMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // plannedPath arrives asynchronously (NavigationScreen resolves it
    // after the first build), so the fit has to react to it changing.
    if (oldWidget.plannedPath.length != widget.plannedPath.length) {
      _fitToPlannedPath();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  /// Frames the whole route, plus the user's own position when it's known,
  /// so they can see both where they are and where they're going.
  void _fitToPlannedPath() {
    if (!_mapReady || widget.plannedPath.length < 2) return;
    final hasPosition = _position.latitude != 0 || _position.longitude != 0;
    _mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: [...widget.plannedPath, if (hasPosition) _position],
        padding: const EdgeInsets.all(48),
        maxZoom: 19,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _position,
        initialZoom: 17,
        onTap: widget.onTap == null ? null : (_, _) => widget.onTap!(),
        onMapReady: () {
          _mapReady = true;
          _fitToPlannedPath();
        },
      ),
      children: [
        TileLayer(
          urlTemplate: kMapTileUrlTemplate,
          userAgentPackageName: kMapUserAgentPackageName,
        ),
        if (widget.plannedPath.length > 1)
          PolylineLayer(
            polylines: [
              Polyline(
                points: widget.plannedPath,
                strokeWidth: 4,
                color: Colors.blueGrey,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            locationPinMarker(_position, Colors.blue),
            ...widget.extraMarkers,
          ],
        ),
      ],
    );
  }
}

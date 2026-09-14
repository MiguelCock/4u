import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import '../services/map_tile_config.dart';

/// Reusable "tap the map to pick a location" screen - pops with the tapped
/// `LatLng` on confirm, or `null` if the admin just backs out. Used by
/// AddPlaceScreen, AddBuildingScreen, and CaptureScreen so latitude/longitude
/// can be set by tapping a map instead of typing coordinates or relying only
/// on device GPS.
///
/// Optionally overlays existing places/buildings/anchor points (each caller
/// opts into whichever are relevant) so an admin can see duplicates and
/// coverage gaps while picking - existing anchor points with a recorded
/// `heading` show a rotated arrow for the direction they were captured
/// facing.
class LocationPickerScreen extends StatefulWidget {
  final LatLng initialPosition;
  final bool showPlaces;
  final bool showBuildings;
  final bool showAnchorPoints;

  /// When set, only anchor points belonging to this building are overlaid -
  /// used by `CaptureScreen`, where anchor points are always scoped to
  /// whichever building is currently selected in the form.
  final String? anchorPointsBuildingId;

  const LocationPickerScreen({
    super.key,
    required this.initialPosition,
    this.showPlaces = false,
    this.showBuildings = false,
    this.showAnchorPoints = false,
    this.anchorPointsBuildingId,
  });

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final _mapApi = MapManagementApi();
  late LatLng _picked;
  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildings = [];
  List<Map<String, dynamic>> _anchorPoints = [];

  @override
  void initState() {
    super.initState();
    _picked = widget.initialPosition;
    _loadOverlayData();
  }

  Future<void> _loadOverlayData() async {
    try {
      final results = await Future.wait([
        widget.showPlaces ? _mapApi.get('/places') : Future.value(const []),
        widget.showBuildings
            ? _mapApi.get('/buildings')
            : Future.value(const []),
        widget.showAnchorPoints
            ? _mapApi.get('/anchor-points')
            : Future.value(const []),
      ]);
      if (!mounted) return;
      final anchorPoints = (results[2] as List).cast<Map<String, dynamic>>();
      setState(() {
        _places = (results[0] as List).cast<Map<String, dynamic>>();
        _buildings = (results[1] as List).cast<Map<String, dynamic>>();
        _anchorPoints = widget.anchorPointsBuildingId == null
            ? anchorPoints
            : anchorPoints
                  .where(
                    (p) => p['building_id'] == widget.anchorPointsBuildingId,
                  )
                  .toList();
      });
    } on ApiException {
      // Overlay data is a convenience, not required to pick a location -
      // fail silently and just show the pick marker on its own.
    }
  }

  List<Marker> _overlayMarkers() {
    final markers = <Marker>[];

    for (final place in _places) {
      final lat = (place['latitude'] as num?)?.toDouble();
      final lng = (place['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      markers.add(
        Marker(
          point: LatLng(lat, lng),
          width: 60,
          height: 60,
          child: const Icon(Icons.flag, color: Colors.purple, size: 30),
        ),
      );
    }

    for (final building in _buildings) {
      final lat = (building['latitude'] as num?)?.toDouble();
      final lng = (building['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      markers.add(
        Marker(
          point: LatLng(lat, lng),
          width: 60,
          height: 60,
          child: const Icon(Icons.apartment, color: Colors.orange, size: 30),
        ),
      );
    }

    for (final point in _anchorPoints) {
      final lat = (point['latitude'] as num?)?.toDouble();
      final lng = (point['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final heading = (point['heading'] as num?)?.toDouble();
      markers.add(
        Marker(
          point: LatLng(lat, lng),
          width: 40,
          height: 40,
          child: heading == null
              ? const Icon(Icons.circle, color: Colors.green, size: 16)
              : Transform.rotate(
                  angle: heading * math.pi / 180,
                  child: const Icon(
                    Icons.navigation,
                    color: Colors.green,
                    size: 28,
                  ),
                ),
        ),
      );
    }

    return markers;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick a location'),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(_picked),
            icon: const Icon(Icons.check),
            tooltip: 'Confirm location',
          ),
        ],
      ),
      body: FlutterMap(
        options: MapOptions(
          initialCenter: _picked,
          initialZoom: 16,
          onTap: (tapPosition, point) => setState(() => _picked = point),
        ),
        children: [
          TileLayer(
            urlTemplate: kMapTileUrlTemplate,
            userAgentPackageName: kMapUserAgentPackageName,
          ),
          MarkerLayer(markers: _overlayMarkers()),
          MarkerLayer(
            markers: [
              Marker(
                point: _picked,
                width: 80,
                height: 80,
                child: const Icon(
                  Icons.location_pin,
                  color: Colors.red,
                  size: 40,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

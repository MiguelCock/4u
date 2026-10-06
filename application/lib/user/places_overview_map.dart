import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import '../services/location_service.dart';
import '../services/map_tile_config.dart';

/// Read-only map of places/buildings, for UserHomeScreen's "see the
/// places" view - same places/buildings fetch LocationPickerScreen already
/// does, minus the tap-to-pick behavior (this screen never returns a
/// value, it's just a browse view).
class PlacesOverviewMap extends StatefulWidget {
  const PlacesOverviewMap({super.key});

  @override
  State<PlacesOverviewMap> createState() => _PlacesOverviewMapState();
}

class _PlacesOverviewMapState extends State<PlacesOverviewMap> {
  final _mapApi = MapManagementApi();
  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildings = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _mapApi.get('/places'),
        _mapApi.get('/buildings'),
      ]);
      if (!mounted) return;
      setState(() {
        _places = (results[0] as List).cast<Map<String, dynamic>>();
        _buildings = (results[1] as List).cast<Map<String, dynamic>>();
      });
    } on ApiException {
      // Browse overlay only - a failed fetch just leaves the map empty
      // rather than blocking the home screen.
    }
  }

  List<Marker> _markers() {
    final markers = <Marker>[];
    for (final place in _places) {
      final lat = (place['latitude'] as num?)?.toDouble();
      final lng = (place['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      markers.add(
        Marker(
          point: LatLng(lat, lng),
          width: 50,
          height: 50,
          child: const Icon(Icons.flag, color: Colors.purple, size: 28),
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
          width: 50,
          height: 50,
          child: const Icon(Icons.apartment, color: Colors.orange, size: 28),
        ),
      );
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final lastPosition = LocationService().lastPosition;
    final center = lastPosition != null
        ? LatLng(lastPosition.latitude, lastPosition.longitude)
        : const LatLng(0, 0);
    return FlutterMap(
      options: MapOptions(initialCenter: center, initialZoom: 15),
      children: [
        TileLayer(
          urlTemplate: kMapTileUrlTemplate,
          userAgentPackageName: kMapUserAgentPackageName,
        ),
        MarkerLayer(markers: _markers()),
      ],
    );
  }
}

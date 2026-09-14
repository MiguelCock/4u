import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/map_tile_config.dart';

/// Reusable "tap the map to pick a location" screen - pops with the tapped
/// `LatLng` on confirm, or `null` if the admin just backs out. Used by
/// AddPlaceScreen, AddBuildingScreen, and CaptureScreen so latitude/longitude
/// can be set by tapping a map instead of typing coordinates or relying only
/// on device GPS.
class LocationPickerScreen extends StatefulWidget {
  final LatLng initialPosition;

  const LocationPickerScreen({super.key, required this.initialPosition});

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  late LatLng _picked;

  @override
  void initState() {
    super.initState();
    _picked = widget.initialPosition;
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

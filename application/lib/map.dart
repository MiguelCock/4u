import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'services/location_service.dart';
import 'services/map_tile_config.dart';

class SimpleMapWidget extends StatefulWidget {
  /// Extra markers layered on top of the live-GPS marker below, e.g. a
  /// corrected-position pin from NavigationScreen. Empty for every other
  /// call site, so this is purely additive.
  final List<Marker> extraMarkers;

  const SimpleMapWidget({super.key, this.extraMarkers = const []});

  @override
  State<SimpleMapWidget> createState() => _SimpleMapWidgetState();
}

class _SimpleMapWidgetState extends State<SimpleMapWidget> {
  final _service = LocationService();
  StreamSubscription<Position>? _subscription;
  late LatLng _position;

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
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      options: MapOptions(initialCenter: _position, initialZoom: 13),
      children: [
        TileLayer(
          urlTemplate: kMapTileUrlTemplate,
          userAgentPackageName: kMapUserAgentPackageName,
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: _position,
              width: 80,
              height: 80,
              child: const Icon(
                Icons.location_pin,
                color: Colors.blue,
                size: 40,
              ),
            ),
            ...widget.extraMarkers,
          ],
        ),
      ],
    );
  }
}

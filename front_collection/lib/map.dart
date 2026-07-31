import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'services/location_service.dart';

class SimpleMapWidget extends StatefulWidget {
  const SimpleMapWidget({super.key});

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
          urlTemplate: 'https://a.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.front_collection',
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
          ],
        ),
      ],
    );
  }
}

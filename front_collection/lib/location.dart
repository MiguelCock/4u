import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'services/location_service.dart';

class LocationInfo extends StatefulWidget {
  const LocationInfo({super.key});

  @override
  State<LocationInfo> createState() => _LocationInfoState();
}

class _LocationInfoState extends State<LocationInfo> {
  final _service = LocationService();
  StreamSubscription<Position>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = _service.positionStream.listen(
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final position = _service.lastPosition;
    if (position == null) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: CircularProgressIndicator(),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16.0),
      color: Colors.grey[200],
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          const Icon(Icons.location_on, color: Colors.blue),
          Text('Lat: ${position.latitude.toStringAsFixed(6)}'),
          Text('Lng: ${position.longitude.toStringAsFixed(6)}'),
          Text('±${position.accuracy.toStringAsFixed(2)}m'),
        ],
      ),
    );
  }
}

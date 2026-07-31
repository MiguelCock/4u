import 'dart:async';
import 'package:geolocator/geolocator.dart';

class LocationService {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  final _controller = StreamController<Position>.broadcast();
  Position? lastPosition;

  Stream<Position> get positionStream => _controller.stream;

  Future<String?> initialize() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return 'Location services are disabled.';

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied)
        return 'Location permissions are denied';
    }
    if (permission == LocationPermission.deniedForever) {
      return 'Location permissions are permanently denied.';
    }

    // Get initial position first
    try {
      lastPosition = await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.bestForNavigation,
        ),
      );
      _controller.add(lastPosition!);
    } catch (_) {}

    // Then stream continuous updates
    Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
        intervalDuration: Duration(seconds: 1),
      ),
    ).listen((position) {
      lastPosition = position;
      _controller.add(position);
    });

    return null;
  }

  void dispose() {
    _controller.close();
    lastPosition = null;
  }
}

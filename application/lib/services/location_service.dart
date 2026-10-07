import 'dart:async';
import 'package:geolocator/geolocator.dart';

enum LocationError {
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
}

class LocationService {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  final _controller = StreamController<Position>.broadcast();
  Position? lastPosition;

  /// Set whenever `initialize()` can't get a position fix, so a widget
  /// that didn't make the original `initialize()` call (or was built after
  /// it already ran) can still show *why* `lastPosition` is stuck at null
  /// instead of guessing from a bare, indefinite loading spinner. An enum
  /// rather than a raw string so callers can pick a localized message and
  /// an appropriate recovery action per case, not string-match English text.
  LocationError? lastError;

  Stream<Position> get positionStream => _controller.stream;

  Future<LocationError?> initialize() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return lastError = LocationError.serviceDisabled;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return lastError = LocationError.permissionDenied;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      return lastError = LocationError.permissionDeniedForever;
    }
    lastError = null;

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

import 'dart:async';
import 'package:geolocator/geolocator.dart';

enum LocationError {
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
}

/// What [LocationService] needs from the platform, so tests can stand in
/// for Geolocator.
class LocationPlatform {
  const LocationPlatform();

  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();
  Future<Position?> lastKnown() => Geolocator.getLastKnownPosition();
  Future<Position> current(Duration timeLimit) => Geolocator.getCurrentPosition(
    locationSettings: AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      timeLimit: timeLimit,
    ),
  );
  Stream<Position> positions() => Geolocator.getPositionStream(
    locationSettings: AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 1,
      intervalDuration: const Duration(seconds: 1),
    ),
  );
  Stream<ServiceStatus> serviceStatus() => Geolocator.getServiceStatusStream();
}

/// The phone's position for the whole app: a broadcast stream, the latest
/// fix, and why there is none.
///
/// It recovers by itself. It used to try once at app start: a phone in
/// battery saver reported location as off at that moment, so the app said
/// "GPS off" for good although it was on, and Find route never started.
/// Now the position stream restarts after an error, location being turned
/// back on restarts it too, and [ensureReady] checks again on demand.
class LocationService {
  static final LocationService _instance = LocationService._internal(
    const LocationPlatform(),
  );
  factory LocationService() => _instance;
  LocationService._internal(this._platform);

  /// A separate instance for tests.
  LocationService.forTesting(this._platform);

  final LocationPlatform _platform;
  final _controller = StreamController<Position>.broadcast();
  StreamSubscription<Position>? _positions;
  StreamSubscription<ServiceStatus>? _status;
  Timer? _restart;
  Position? lastPosition;

  /// Set whenever `initialize()` can't get a position fix, so a widget
  /// that didn't make the original `initialize()` call (or was built after
  /// it already ran) can still show *why* `lastPosition` is stuck at null
  /// instead of guessing from a bare, indefinite loading spinner. An enum
  /// rather than a raw string so callers can pick a localized message and
  /// an appropriate recovery action per case, not string-match English text.
  LocationError? lastError;

  Stream<Position> get positionStream => _controller.stream;

  /// Checks the service and permission and starts the position stream.
  /// Doesn't wait for a fix: the first one arrives on [positionStream]
  /// (see [ensureReady] to wait for it).
  Future<LocationError?> initialize() async {
    _status ??= _platform.serviceStatus().listen((status) {
      if (status == ServiceStatus.enabled) {
        initialize();
      } else {
        lastError = LocationError.serviceDisabled;
      }
    }, onError: (_) {});

    if (!await _platform.isServiceEnabled()) {
      return lastError = LocationError.serviceDisabled;
    }

    var permission = await _platform.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await _platform.requestPermission();
      if (permission == LocationPermission.denied) {
        return lastError = LocationError.permissionDenied;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      return lastError = LocationError.permissionDeniedForever;
    }
    lastError = null;

    if (lastPosition == null) {
      try {
        final known = await _platform.lastKnown();
        if (known != null && lastPosition == null) _publish(known);
      } catch (_) {}
      unawaited(_firstFix());
    }
    _startStream();
    return null;
  }

  Future<void> _firstFix() async {
    try {
      _publish(await _platform.current(const Duration(seconds: 10)));
    } catch (_) {
      // The stream delivers one later.
    }
  }

  void _startStream() {
    if (_positions != null) return;
    _positions = _platform.positions().listen(
      _publish,
      onError: (_) => _restartLater(),
      onDone: _restartLater,
    );
  }

  void _restartLater() {
    _positions?.cancel();
    _positions = null;
    _restart?.cancel();
    _restart = Timer(const Duration(seconds: 3), initialize);
  }

  void _publish(Position position) {
    lastPosition = position;
    lastError = null;
    _controller.add(position);
  }

  /// A position to plan a trip from, waiting up to [timeout] for the first
  /// fix (re-checking location first). Returns null with [lastError] set
  /// only when location really is off or not allowed; null with no error
  /// means no fix arrived in time.
  Future<Position?> ensureReady({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final error = await initialize();
    if (error != null) return null;
    final position = lastPosition;
    if (position != null) return position;
    try {
      return await positionStream.first.timeout(timeout);
    } on TimeoutException {
      return lastPosition;
    }
  }

  void dispose() {
    _positions?.cancel();
    _status?.cancel();
    _restart?.cancel();
    _controller.close();
    lastPosition = null;
  }
}

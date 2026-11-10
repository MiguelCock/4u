import 'package:flutter/foundation.dart';
import 'dart:async';

import 'package:eyes4u/services/location_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

Position _fix(double lat) => Position(
  latitude: lat,
  longitude: -75.58,
  timestamp: DateTime(2026, 10, 28),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

class _FakePlatform extends LocationPlatform {
  bool enabled = false;
  final positionsCtl = StreamController<Position>.broadcast();
  final statusCtl = StreamController<ServiceStatus>.broadcast();
  int streams = 0;

  @override
  Future<bool> isServiceEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<LocationPermission> requestPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<Position?> lastKnown() async => null;
  @override
  Future<Position> current(Duration timeLimit) => Completer<Position>().future; // never answers: the stream does
  @override
  Stream<Position> positions() {
    streams++;
    return positionsCtl.stream;
  }

  @override
  Stream<ServiceStatus> serviceStatus() => statusCtl.stream;
}

void main() {
  test('location turned on later starts the stream by itself', () async {
    final platform = _FakePlatform();
    final service = LocationService.forTesting(platform);
    expect(await service.initialize(), LocationError.serviceDisabled);
    expect(platform.streams, 0);

    platform.enabled = true;
    platform.statusCtl.add(ServiceStatus.enabled);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(platform.streams, 1);
    expect(service.lastError, isNull);

    platform.positionsCtl.add(_fix(6.2));
    await Future<void>.delayed(Duration.zero);
    expect(service.lastPosition?.latitude, 6.2);
  });

  test('ensureReady waits for the first fix', () async {
    final platform = _FakePlatform()..enabled = true;
    final service = LocationService.forTesting(platform);
    final ready = service.ensureReady(timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    platform.positionsCtl.add(_fix(6.3));
    expect((await ready)?.latitude, 6.3);
  });

  test('a platform without a service-status stream still starts', () async {
    final platform = _NoStatusPlatform()..enabled = true;
    final service = LocationService.forTesting(platform);
    expect(await service.initialize(), isNull);
    expect(platform.streams, 1);
  });

  test('ensureReady gives up quietly without a fix', () async {
    final platform = _FakePlatform()..enabled = true;
    final service = LocationService.forTesting(platform);
    final position = await service.ensureReady(
      timeout: const Duration(milliseconds: 50),
    );
    expect(position, isNull);
    expect(service.lastError, isNull);
  });

  group('positionSettings', () {
    test('Android: every second, standing still too', () {
      final s = positionSettings(TargetPlatform.android) as AndroidSettings;
      expect(s.accuracy, LocationAccuracy.bestForNavigation);
      expect(s.distanceFilter, 0);
      expect(s.intervalDuration, const Duration(seconds: 1));
    });

    test('iOS keeps updating when the user stops (#160)', () {
      final s =
          positionSettings(
                TargetPlatform.iOS,
                timeLimit: const Duration(seconds: 10),
              )
              as AppleSettings;
      expect(s.accuracy, LocationAccuracy.bestForNavigation);
      expect(s.distanceFilter, 0);
      expect(s.pauseLocationUpdatesAutomatically, isFalse);
      expect(s.timeLimit, const Duration(seconds: 10));
    });

    test('elsewhere (the web): plain settings', () {
      final s = positionSettings(TargetPlatform.linux);
      expect(s, isNot(isA<AndroidSettings>()));
      expect(s, isNot(isA<AppleSettings>()));
      expect(s.accuracy, LocationAccuracy.bestForNavigation);
    });
  });
}

class _NoStatusPlatform extends _FakePlatform {
  @override
  Stream<ServiceStatus> serviceStatus() =>
      throw UnsupportedError('getServiceStatusStream'); // like the web
}

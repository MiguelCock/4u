import 'dart:async';

import 'package:camera/camera.dart';
import 'package:eyes4u/user/trip_sensors.dart';

/// The phone's sensors for the trip screen, fed by hand: no camera, no
/// motion, and a compass and barometer that say what a test tells them.
class FakeTripSensors extends TripSensors {
  FakeTripSensors();

  final _compass = StreamController<CompassReading>.broadcast();
  final _pressure = StreamController<double>.broadcast();
  final awake = <bool>[];

  void face(double heading) => _compass.add((heading: heading, accuracy: 10));
  void pressureIs(double hPa) => _pressure.add(hPa);

  @override
  Stream<CompassReading>? compass() => _compass.stream;
  @override
  Stream<AxisReading> accelerometer() => const Stream.empty();
  @override
  Stream<AxisReading> gyroscope() => const Stream.empty();
  @override
  Stream<double> pressure() => _pressure.stream;
  @override
  Future<CameraController?> camera() async => null;
  @override
  Future<void> keepAwake(bool on) async => awake.add(on);
  @override
  Future<Map<String, dynamic>> device() async => {'model': 'test'};
}

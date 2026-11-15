import 'package:camera/camera.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/camera_helper.dart';
import '../services/device_details.dart';

/// A compass reading: where the top of the phone points, and how sure.
typedef CompassReading = ({double? heading, double? accuracy});

/// A three-axis reading (accelerometer in m/s², gyroscope in rad/s).
typedef AxisReading = ({double x, double y, double z});

/// What the trip screen reads from the phone itself (#268's Phase C): the
/// compass, motion and pressure sensors, the camera, the screen staying on,
/// and the device's details. The real one calls the plugins; tests give a
/// fake that's fed by hand.
class TripSensors {
  const TripSensors();

  /// Null on platforms without a compass.
  Stream<CompassReading>? compass() => FlutterCompass.events?.map(
    (e) => (heading: e.heading, accuracy: e.accuracy),
  );

  Stream<AxisReading> accelerometer() => accelerometerEventStream(
    samplingPeriod: SensorInterval.gameInterval,
  ).map((e) => (x: e.x, y: e.y, z: e.z));

  Stream<AxisReading> gyroscope() => gyroscopeEventStream(
    samplingPeriod: SensorInterval.gameInterval,
  ).map((e) => (x: e.x, y: e.y, z: e.z));

  /// Air pressure in hPa, for the floor changes.
  Stream<double> pressure() => barometerEventStream().map((e) => e.pressure);

  /// Null when unavailable (no hardware, permission denied...).
  Future<CameraController?> camera() => initCamera();

  /// Keeps the screen on during a trip: off, it stops the camera, GPS and
  /// timers without a word. Best effort.
  Future<void> keepAwake(bool on) =>
      (on ? WakelockPlus.enable() : WakelockPlus.disable()).catchError((_) {});

  Future<Map<String, dynamic>> device() => deviceDetails();
}

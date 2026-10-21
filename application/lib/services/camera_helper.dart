import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

/// Requests camera permission and returns an initialized back-camera
/// controller, or null on any denial/failure (no hardware, permission
/// denied, init error). Callers own disposing the controller, and must
/// treat null as "no visual input" rather than an error - the camera is
/// always an enhancement here, never a requirement.
Future<CameraController?> initCamera() async {
  if (await Permission.camera.request() != PermissionStatus.granted) {
    return null;
  }
  try {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return null;
    final controller = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    await controller.initialize();
    return controller;
  } catch (_) {
    return null;
  }
}

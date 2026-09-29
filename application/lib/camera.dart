import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path/path.dart' as path;
import 'services/api_service.dart';
import 'services/location_service.dart';

class SimpleCameraWidget extends StatefulWidget {
  const SimpleCameraWidget({super.key});

  @override
  State<SimpleCameraWidget> createState() => _SimpleCameraWidgetState();
}

class _SimpleCameraWidgetState extends State<SimpleCameraWidget> {
  CameraController? _controller;
  Future<void>? _initializeFuture;
  final _service = LocationService();
  StreamSubscription<Position>? _subscription;
  StreamSubscription<CompassEvent>? _compassSubscription;
  double? _liveHeading;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _subscription = _service.positionStream.listen(
      (_) => mounted ? setState(() {}) : null,
    );
    _compassSubscription = FlutterCompass.events?.listen((event) {
      if (mounted) {
        // `heading` is what the Android plugin actually computes from the
        // device's sensors - `headingForCameraMode` is a real iOS feature
        // but the Android implementation never populates it (stays 0.0,
        // not null, so `??` never falls through) and this app is
        // Android-only today (no ios/ directory in the repo).
        setState(
          () => _liveHeading = event.heading ?? event.headingForCameraMode,
        );
      }
    });
  }

  Future<void> _initCamera() async {
    if (await Permission.camera.request() != PermissionStatus.granted) {
      // print('Camera permission denied');
      return;
    }
    try {
      final cameras = await availableCameras();
      _controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      _initializeFuture = _controller!.initialize();
      await _initializeFuture;
      setState(() {});
    } catch (e) {
      // print('Camera init error: $e');
    }
  }

  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      final image = await _controller!.takePicture();

      final position = _service.lastPosition;
      if (position == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location not available')),
          );
        }
        return;
      }
      final heading = _liveHeading;
      await _sendPhotoToServer(image, position, heading);
    } catch (e) {
      return;
    }
  }

  Future<void> _sendPhotoToServer(
    XFile image,
    Position position,
    double? heading,
  ) async {
    try {
      final bytes = await image.readAsBytes();

      await DataCollectionApi().postMultipart(
        '/upload',
        fieldName: 'image',
        bytes: bytes,
        filename: path.basename(image.path),
        fields: {
          'latitude': position.latitude.toString(),
          'longitude': position.longitude.toString(),
          'accuracy': position.accuracy.toString(),
          if (heading != null) 'heading': heading.toString(),
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Photo uploaded!')));
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: ${e.statusCode}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _subscription?.cancel();
    _compassSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_controller!),
        Positioned(
          bottom: 32,
          left: 0,
          right: 0,
          child: Center(
            child: FloatingActionButton(
              onPressed: _takePhoto,
              child: const Icon(Icons.camera),
            ),
          ),
        ),
      ],
    );
  }
}

import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http_parser/http_parser.dart'; // for MediaType
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
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

  @override
  void initState() {
    super.initState();
    _initCamera();
    _subscription = _service.positionStream.listen(
      (_) => mounted ? setState(() {}) : null,
    );
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
      await _sendPhotoToServer(image, position);
    } catch (e) {
      return;
    }
  }

  Future<void> _sendPhotoToServer(XFile image, Position position) async {
    try {
      final bytes = await image.readAsBytes();

      final uri = Uri.parse('http://10.10.79.249:3000/upload');
      final request = http.MultipartRequest('POST', uri)
        ..files.add(
          http.MultipartFile.fromBytes(
            'image',
            bytes,
            filename: path.basename(image.path),
            contentType: MediaType('image', 'jpeg'),
          ),
        )
        ..fields['latitude'] = position.latitude.toString()
        ..fields['longitude'] = position.longitude.toString()
        ..fields['accuracy'] = position.accuracy.toString();

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Photo uploaded!')));
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Upload failed: ${response.statusCode}')),
          );
        }
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

import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path/path.dart' as path;
import 'l10n/app_localizations.dart';
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

  /// Set on permission denial or any camera init failure, so build() can
  /// show a real error with a recovery action instead of an infinite
  /// spinner forever (#84).
  String? _error;
  bool _permissionPermanentlyDenied = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _subscription = _service.positionStream.listen(
      (_) => mounted ? setState(() {}) : null,
    );
    _compassSubscription = FlutterCompass.events?.listen((event) {
      if (mounted) {
        setState(
          () => _liveHeading = event.heading ?? event.headingForCameraMode,
        );
      }
    });
  }

  Future<void> _initCamera() async {
    setState(() {
      _error = null;
      _permissionPermanentlyDenied = false;
    });
    final status = await Permission.camera.request();
    if (status != PermissionStatus.granted) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(context)!.cameraPermissionDeniedError;
        _permissionPermanentlyDenied = status.isPermanentlyDenied;
      });
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
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = AppLocalizations.of(
          context,
        )!.cameraUnavailableError(e.toString()),
      );
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
            SnackBar(
              content: Text(
                AppLocalizations.of(context)!.cameraLocationNotAvailable,
              ),
            ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.cameraPhotoUploaded),
          ),
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(
                context,
              )!.cameraUploadFailedStatus(e.statusCode),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(
                context,
              )!.cameraUnavailableError(e.toString()),
            ),
          ),
        );
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
    final l10n = AppLocalizations.of(context)!;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _permissionPermanentlyDenied
                    ? openAppSettings
                    : _initCamera,
                child: Text(
                  _permissionPermanentlyDenied
                      ? l10n.commonOpenSettings
                      : l10n.commonTryAgain,
                ),
              ),
            ],
          ),
        ),
      );
    }

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

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api_service.dart';

class _PhotoEntry {
  final String? id;
  final String? imageUrl;
  final File? localFile;
  final double? heading;
  final bool uploading;

  const _PhotoEntry({
    this.id,
    this.imageUrl,
    this.localFile,
    this.heading,
    this.uploading = false,
  });
}

/// Multi-photo capture loop for a single `anchor_points` row - one physical
/// point typically ends up with ~4-8 photos facing different directions, so
/// this screen is reached both right after creating a point (`CaptureScreen`)
/// and later via `AdminHomeScreen`'s "Add photo" action on an existing one.
class CapturePhotoScreen extends StatefulWidget {
  final String anchorPointId;
  final String anchorPointDescription;

  const CapturePhotoScreen({
    super.key,
    required this.anchorPointId,
    required this.anchorPointDescription,
  });

  @override
  State<CapturePhotoScreen> createState() => _CapturePhotoScreenState();
}

class _CapturePhotoScreenState extends State<CapturePhotoScreen> {
  final _mapApi = MapManagementApi();
  final _aiTrainingApi = AiTrainingApi();

  CameraController? _controller;
  StreamSubscription<CompassEvent>? _compassSubscription;
  double? _liveHeading;
  final List<_PhotoEntry> _photos = [];
  Map<String, dynamic>? _anchorPoint;
  bool _loadingExisting = true;
  bool _capturing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _loadAnchorPoint();
    _loadExistingPhotos();
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
    if (await Permission.camera.request() != PermissionStatus.granted) return;
    try {
      final cameras = await availableCameras();
      _controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _controller!.initialize();
      if (mounted) setState(() {});
    } catch (_) {
      // Camera unavailable (e.g. emulator/CI) - the rest of the form still works.
    }
  }

  Future<void> _loadAnchorPoint() async {
    try {
      final result = await _mapApi.get(
        '/anchor-points/${widget.anchorPointId}',
      );
      if (!mounted) return;
      if (result is Map) {
        setState(() => _anchorPoint = result.cast<String, dynamic>());
      }
    } on ApiException {
      // Only needed to decide whether to auto-index new photos below - not
      // required for the rest of this screen to work.
    }
  }

  Future<void> _loadExistingPhotos() async {
    try {
      final result = await _mapApi.get(
        '/anchor-points/${widget.anchorPointId}/photos',
      );
      if (!mounted) return;
      if (result is List) {
        setState(() {
          _photos.addAll(
            result.cast<Map<String, dynamic>>().map(
              (p) => _PhotoEntry(
                id: p['id'] as String,
                imageUrl: p['image_url'] as String?,
                heading: (p['heading'] as num?)?.toDouble(),
              ),
            ),
          );
        });
      }
    } on ApiException catch (e) {
      setState(() => _error = 'Failed to load existing photos: $e');
    } finally {
      if (mounted) setState(() => _loadingExisting = false);
    }
  }

  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      setState(() => _error = 'Not signed in.');
      return;
    }

    setState(() {
      _capturing = true;
      _error = null;
    });

    final heading = _liveHeading;
    File? localFile;
    try {
      final image = await _controller!.takePicture();
      localFile = File(image.path);
      setState(
        () => _photos.add(
          _PhotoEntry(localFile: localFile, heading: heading, uploading: true),
        ),
      );

      final bytes = await localFile.readAsBytes();
      final uploadResult = await _mapApi.postMultipart(
        '/anchor-points/upload-image',
        fieldName: 'file',
        bytes: bytes,
        filename: '${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      final imageUrl = (uploadResult as Map<String, dynamic>)['url'] as String;

      final photoResult = await _mapApi.post(
        '/anchor-points/${widget.anchorPointId}/photos',
        {'image_url': imageUrl, 'heading': heading, 'captured_by': userId},
      );
      final id = (photoResult as List).first['id'] as String;

      if (!mounted) return;
      setState(() {
        final index = _photos.indexWhere(
          (p) => p.uploading && p.localFile?.path == localFile!.path,
        );
        if (index != -1) {
          _photos[index] = _PhotoEntry(
            id: id,
            imageUrl: imageUrl,
            localFile: localFile,
            heading: heading,
          );
        }
      });

      // Only confirmed-good anchor points are searchable - if this point is
      // already verified, keep it that way by indexing the new photo too,
      // instead of only re-indexing on the next edit-screen save.
      if (_anchorPoint?['status'] == 'verified') {
        try {
          await _aiTrainingApi.post('/index_anchor', {
            'anchor_point_id': widget.anchorPointId,
            'latitude': _anchorPoint!['latitude'],
            'longitude': _anchorPoint!['longitude'],
            'building_id': _anchorPoint!['building_id'],
            'photos': [
              {'photo_id': id, 'image_url': imageUrl, 'heading': heading},
            ],
          });
        } on ApiException catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Saved, but indexing failed: $e')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (localFile != null) {
            _photos.removeWhere(
              (p) => p.uploading && p.localFile?.path == localFile!.path,
            );
          }
          _error = 'Failed to save photo: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _deletePhoto(_PhotoEntry photo) async {
    if (photo.id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete photo?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _mapApi.delete('/anchor-point-photos/${photo.id}');
      if (mounted) setState(() => _photos.remove(photo));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
      }
      return;
    }

    // Best-effort - cheap no-op if this photo was never indexed (e.g. the
    // anchor point isn't verified), doesn't affect the delete above either way.
    try {
      await _aiTrainingApi.delete('/index_photo/${photo.id}');
    } on ApiException {
      // Nothing to show the admin - the photo is already gone either way.
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _compassSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Photos: ${widget.anchorPointDescription}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Stack(
            children: [
              SizedBox(
                height: 300,
                width: double.infinity,
                child: (_controller != null && _controller!.value.isInitialized)
                    ? CameraPreview(_controller!)
                    : const Center(child: CircularProgressIndicator()),
              ),
              if (_liveHeading != null)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Facing: ${_liveHeading!.round()}°',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: ElevatedButton.icon(
              onPressed: _capturing ? null : _takePhoto,
              icon: _capturing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.camera_alt),
              label: Text(
                _capturing ? 'Saving...' : 'Take photo (${_photos.length})',
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          const Divider(height: 1),
          Expanded(
            child: _loadingExisting
                ? const Center(child: CircularProgressIndicator())
                : _photos.isEmpty
                ? const Center(child: Text('No photos yet - take one above.'))
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                        ),
                    itemCount: _photos.length,
                    itemBuilder: (context, index) {
                      final photo = _photos[index];
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          photo.localFile != null
                              ? Image.file(photo.localFile!, fit: BoxFit.cover)
                              : Image.network(
                                  photo.imageUrl!,
                                  fit: BoxFit.cover,
                                ),
                          if (photo.uploading)
                            const ColoredBox(
                              color: Colors.black45,
                              child: Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation(
                                    Colors.white,
                                  ),
                                ),
                              ),
                            )
                          else
                            Positioned(
                              top: 0,
                              right: 0,
                              child: IconButton(
                                icon: const Icon(
                                  Icons.delete,
                                  color: Colors.white,
                                ),
                                onPressed: () => _deletePhoto(photo),
                              ),
                            ),
                          if (photo.heading != null)
                            Positioned(
                              bottom: 0,
                              left: 0,
                              child: Container(
                                color: Colors.black54,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Text(
                                  '${photo.heading!.round()}°',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api_service.dart';
import '../services/location_service.dart';
import 'location_picker_screen.dart';

/// Matches db_schema/location_type.sql's seeded values — static reference
/// data with no CRUD endpoint anywhere, so hardcoded here rather than
/// fetched (same reasoning as roles.sql in auth/signup_screen.dart).
const Map<int, String> kLocationTypes = {
  1: 'entrance',
  2: 'intersection',
  3: 'elevator',
  4: 'stairwell',
  5: 'classroom',
  6: 'office',
  7: 'restroom',
  8: 'cafeteria',
  9: 'other',
};

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _mapApi = MapManagementApi();
  final _locationService = LocationService();

  CameraController? _controller;
  XFile? _capturedImage;
  LatLng? _pickedPosition;
  StreamSubscription<CompassEvent>? _compassSubscription;
  double? _liveHeading;
  double? _capturedHeading;
  List<Map<String, dynamic>> _buildings = [];
  String? _selectedBuildingId;
  int _selectedLocationTypeId = kLocationTypes.keys.first;
  final _descriptionController = TextEditingController();
  bool _loadingBuildings = true;
  bool _submitting = false;
  String? _error;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _loadBuildings();
    _compassSubscription = FlutterCompass.events?.listen((event) {
      if (mounted) {
        setState(
          () => _liveHeading = event.headingForCameraMode ?? event.heading,
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

  Future<void> _loadBuildings() async {
    try {
      final result = await _mapApi.get('/buildings');
      if (result is List) {
        setState(() {
          _buildings = result.cast<Map<String, dynamic>>();
          if (_buildings.isNotEmpty) {
            _selectedBuildingId = _buildings.first['id'] as String?;
          }
        });
      }
    } on ApiException catch (e) {
      setState(() => _error = 'Failed to load buildings: $e');
    } finally {
      if (mounted) setState(() => _loadingBuildings = false);
    }
  }

  Future<void> _pickOnMap() async {
    final fallback = _locationService.lastPosition;
    final initial =
        _pickedPosition ??
        (fallback != null
            ? LatLng(fallback.latitude, fallback.longitude)
            : const LatLng(0, 0));
    final result = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialPosition: initial,
          showBuildings: true,
          showAnchorPoints: true,
          anchorPointsBuildingId: _selectedBuildingId,
        ),
      ),
    );
    if (result != null) setState(() => _pickedPosition = result);
  }

  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      final image = await _controller!.takePicture();
      setState(() {
        _capturedImage = image;
        _capturedHeading = _liveHeading;
      });
    } catch (e) {
      setState(() => _error = 'Failed to capture photo: $e');
    }
  }

  Future<void> _submit() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final position = _locationService.lastPosition;
    if (userId == null) {
      setState(() => _error = 'Not signed in.');
      return;
    }
    if (_capturedImage == null) {
      setState(() => _error = 'Take a photo first.');
      return;
    }
    if (_selectedBuildingId == null) {
      setState(() => _error = 'Select a building.');
      return;
    }
    if (position == null && _pickedPosition == null) {
      setState(
        () => _error =
            'Location not available - wait for GPS or pick on the map.',
      );
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
      _successMessage = null;
    });

    try {
      final bytes = await _capturedImage!.readAsBytes();
      final uploadResult = await _mapApi.postMultipart(
        '/anchor-points/upload-image',
        fieldName: 'file',
        bytes: bytes,
        filename: '${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      final imageUrl = (uploadResult as Map<String, dynamic>)['url'] as String;

      await _mapApi.post('/anchor-points', {
        'building_id': _selectedBuildingId,
        'location_type_id': _selectedLocationTypeId,
        'image_url': imageUrl,
        'latitude': _pickedPosition?.latitude ?? position!.latitude,
        'longitude': _pickedPosition?.longitude ?? position!.longitude,
        'altitude': position?.altitude,
        'heading': _capturedHeading,
        if (_descriptionController.text.trim().isNotEmpty)
          'location_description': _descriptionController.text.trim(),
        'captured_by': userId,
      });

      setState(() {
        _successMessage = 'Anchor point saved.';
        _capturedImage = null;
        _capturedHeading = null;
        _descriptionController.clear();
      });
    } on ApiException catch (e) {
      setState(() => _error = 'Failed to save anchor point: $e');
    } catch (e) {
      setState(() => _error = 'Failed to save anchor point: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _descriptionController.dispose();
    _compassSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Capture anchor point')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                SizedBox(
                  height: 300,
                  width: double.infinity,
                  child: _capturedImage != null
                      ? Image.file(
                          File(_capturedImage!.path),
                          fit: BoxFit.cover,
                        )
                      : (_controller != null &&
                            _controller!.value.isInitialized)
                      ? CameraPreview(_controller!)
                      : const Center(child: CircularProgressIndicator()),
                ),
                if (_capturedImage == null && _liveHeading != null)
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
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _takePhoto,
              child: Text(
                _capturedImage == null ? 'Take photo' : 'Retake photo',
              ),
            ),
            const SizedBox(height: 16),
            if (_loadingBuildings)
              const Center(child: CircularProgressIndicator())
            else
              DropdownButtonFormField<String>(
                initialValue: _selectedBuildingId,
                decoration: const InputDecoration(labelText: 'Building'),
                items: _buildings
                    .map(
                      (b) => DropdownMenuItem(
                        value: b['id'] as String,
                        child: Text(b['name'] as String? ?? b['id'] as String),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setState(() => _selectedBuildingId = value),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _selectedLocationTypeId,
              decoration: const InputDecoration(labelText: 'Location type'),
              items: kLocationTypes.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: (value) =>
                  setState(() => _selectedLocationTypeId = value!),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _pickedPosition != null
                  ? 'Location (picked): ${_pickedPosition!.latitude.toStringAsFixed(6)}, ${_pickedPosition!.longitude.toStringAsFixed(6)}'
                  : _locationService.lastPosition != null
                  ? 'Location (GPS): ${_locationService.lastPosition!.latitude.toStringAsFixed(6)}, ${_locationService.lastPosition!.longitude.toStringAsFixed(6)}'
                  : 'Location: not available yet',
            ),
            if (_capturedImage != null)
              Text(
                _capturedHeading != null
                    ? 'Heading (captured): ${_capturedHeading!.round()}°'
                    : 'Heading: not available for this photo',
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickOnMap,
              icon: const Icon(Icons.map),
              label: const Text('Pick on map'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            if (_successMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _successMessage!,
                style: const TextStyle(color: Colors.green),
              ),
            ],
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save anchor point'),
            ),
          ],
        ),
      ),
    );
  }
}

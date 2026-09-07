import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api_service.dart';
import '../services/location_service.dart';

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
  }

  Future<void> _initCamera() async {
    if (await Permission.camera.request() != PermissionStatus.granted) return;
    try {
      final cameras = await availableCameras();
      _controller = CameraController(cameras.first, ResolutionPreset.medium, enableAudio: false);
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

  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      final image = await _controller!.takePicture();
      setState(() => _capturedImage = image);
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
    if (position == null) {
      setState(() => _error = 'Location not available yet.');
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
        'latitude': position.latitude,
        'longitude': position.longitude,
        'altitude': position.altitude,
        if (_descriptionController.text.trim().isNotEmpty)
          'location_description': _descriptionController.text.trim(),
        'captured_by': userId,
      });

      setState(() {
        _successMessage = 'Anchor point saved.';
        _capturedImage = null;
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
            SizedBox(
              height: 300,
              child: _capturedImage != null
                  ? Image.file(File(_capturedImage!.path), fit: BoxFit.cover)
                  : (_controller != null && _controller!.value.isInitialized)
                      ? CameraPreview(_controller!)
                      : const Center(child: CircularProgressIndicator()),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _takePhoto,
              child: Text(_capturedImage == null ? 'Take photo' : 'Retake photo'),
            ),
            const SizedBox(height: 16),
            if (_loadingBuildings)
              const Center(child: CircularProgressIndicator())
            else
              DropdownButtonFormField<String>(
                value: _selectedBuildingId,
                decoration: const InputDecoration(labelText: 'Building'),
                items: _buildings
                    .map(
                      (b) => DropdownMenuItem(
                        value: b['id'] as String,
                        child: Text(b['name'] as String? ?? b['id'] as String),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _selectedBuildingId = value),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: _selectedLocationTypeId,
              decoration: const InputDecoration(labelText: 'Location type'),
              items: kLocationTypes.entries
                  .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: (value) => setState(() => _selectedLocationTypeId = value!),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(labelText: 'Description (optional)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            if (_successMessage != null) ...[
              const SizedBox(height: 12),
              Text(_successMessage!, style: const TextStyle(color: Colors.green)),
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

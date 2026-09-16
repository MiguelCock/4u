import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import '../services/location_service.dart';
import 'capture_photo_screen.dart';
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

/// Creates a new `anchor_points` row (position + description only — no
/// photos live here anymore, since one physical point ends up with ~4-8
/// photos). On success, hands off to `CapturePhotoScreen` to take them.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _mapApi = MapManagementApi();
  final _locationService = LocationService();
  final _descriptionController = TextEditingController();

  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildingsAll = [];
  List<Map<String, dynamic>> _buildings = [];
  String? _selectedPlaceId;
  String? _selectedBuildingId;
  int _selectedLocationTypeId = kLocationTypes.keys.first;
  LatLng? _pickedPosition;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final results = await Future.wait([
        _mapApi.get('/places'),
        _mapApi.get('/buildings'),
      ]);
      if (!mounted) return;
      setState(() {
        _places = (results[0] as List).cast<Map<String, dynamic>>();
        _buildingsAll = (results[1] as List).cast<Map<String, dynamic>>();
        if (_places.isNotEmpty) {
          _selectedPlaceId = _places.first['id'] as String?;
        }
        _applyBuildingFilter();
      });
    } on ApiException catch (e) {
      setState(() => _error = 'Failed to load places/buildings: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyBuildingFilter() {
    _buildings = _buildingsAll
        .where((b) => b['place_id'] == _selectedPlaceId)
        .toList();
    _selectedBuildingId = _buildings.isNotEmpty
        ? _buildings.first['id'] as String?
        : null;
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
          buildingsPlaceId: _selectedPlaceId,
          anchorPointsBuildingId: _selectedBuildingId,
        ),
      ),
    );
    if (result != null) setState(() => _pickedPosition = result);
  }

  Future<void> _submit() async {
    final position = _locationService.lastPosition;
    final description = _descriptionController.text.trim();

    if (_selectedPlaceId == null) {
      setState(() => _error = 'Select a place.');
      return;
    }
    if (_selectedBuildingId == null) {
      setState(() => _error = 'Select a building.');
      return;
    }
    if (description.isEmpty) {
      setState(() => _error = 'Description is required.');
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
    });

    try {
      final result = await _mapApi.post('/anchor-points', {
        'building_id': _selectedBuildingId,
        'location_type_id': _selectedLocationTypeId,
        'latitude': _pickedPosition?.latitude ?? position!.latitude,
        'longitude': _pickedPosition?.longitude ?? position!.longitude,
        'altitude': position?.altitude,
        'location_description': description,
      });
      final id = (result as List).first['id'] as String;

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CapturePhotoScreen(
            anchorPointId: id,
            anchorPointDescription: description,
          ),
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
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
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New anchor point')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_places.isEmpty)
                    const Text(
                      'No places exist yet - add one first (Add place).',
                      style: TextStyle(color: Colors.red),
                    )
                  else
                    DropdownButtonFormField<String>(
                      initialValue: _selectedPlaceId,
                      decoration: const InputDecoration(labelText: 'Place'),
                      items: _places
                          .map(
                            (p) => DropdownMenuItem(
                              value: p['id'] as String,
                              child: Text(
                                p['name'] as String? ?? p['id'] as String,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) => setState(() {
                        _selectedPlaceId = value;
                        _applyBuildingFilter();
                      }),
                    ),
                  const SizedBox(height: 12),
                  if (_places.isNotEmpty && _buildings.isEmpty)
                    const Text(
                      'No buildings in this place yet - add one first (Add building).',
                      style: TextStyle(color: Colors.red),
                    )
                  else if (_buildings.isNotEmpty)
                    DropdownButtonFormField<String>(
                      initialValue: _selectedBuildingId,
                      decoration: const InputDecoration(labelText: 'Building'),
                      items: _buildings
                          .map(
                            (b) => DropdownMenuItem(
                              value: b['id'] as String,
                              child: Text(
                                b['name'] as String? ?? b['id'] as String,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _selectedBuildingId = value),
                    ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _selectedLocationTypeId,
                    decoration: const InputDecoration(
                      labelText: 'Location type',
                    ),
                    items: kLocationTypes.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _selectedLocationTypeId = value!),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _descriptionController,
                    decoration: const InputDecoration(
                      labelText: 'Description',
                      helperText:
                          'Required - used as this point\'s name so it can be told apart from others.',
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
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Create and add photos'),
                  ),
                ],
              ),
            ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import '../services/location_service.dart';
import 'location_picker_screen.dart';

/// Admin form to create a `buildings` row under an existing place - the
/// building dropdown in `capture_screen.dart` is populated from these.
class AddBuildingScreen extends StatefulWidget {
  const AddBuildingScreen({super.key});

  @override
  State<AddBuildingScreen> createState() => _AddBuildingScreenState();
}

class _AddBuildingScreenState extends State<AddBuildingScreen> {
  final _mapApi = MapManagementApi();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _floorsController = TextEditingController(text: '1');
  late final TextEditingController _latController;
  late final TextEditingController _lngController;

  List<Map<String, dynamic>> _places = [];
  String? _selectedPlaceId;
  bool _hasElevator = false;
  bool _hasStairs = true;
  bool _loadingPlaces = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final position = LocationService().lastPosition;
    _latController = TextEditingController(
      text: position?.latitude.toString() ?? '',
    );
    _lngController = TextEditingController(
      text: position?.longitude.toString() ?? '',
    );
    _loadPlaces();
  }

  Future<void> _loadPlaces() async {
    try {
      final result = await _mapApi.get('/places');
      if (result is List) {
        setState(() {
          _places = result.cast<Map<String, dynamic>>();
          if (_places.isNotEmpty) {
            _selectedPlaceId = _places.first['id'] as String?;
          }
        });
      }
    } on ApiException catch (e) {
      setState(() => _error = 'Failed to load places: $e');
    } finally {
      if (mounted) setState(() => _loadingPlaces = false);
    }
  }

  Future<void> _pickOnMap() async {
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    final initial = (lat != null && lng != null)
        ? LatLng(lat, lng)
        : const LatLng(0, 0);
    final result = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialPosition: initial,
          showPlaces: true,
          showBuildings: true,
        ),
      ),
    );
    if (result != null) {
      setState(() {
        _latController.text = result.latitude.toString();
        _lngController.text = result.longitude.toString();
      });
    }
  }

  Future<void> _submit() async {
    final code = _codeController.text.trim();
    final name = _nameController.text.trim();
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    final floors = int.tryParse(_floorsController.text.trim()) ?? 1;
    if (_selectedPlaceId == null) {
      setState(() => _error = 'Select a place.');
      return;
    }
    if (code.isEmpty || name.isEmpty || lat == null || lng == null) {
      setState(
        () => _error = 'Code, name, latitude and longitude are required.',
      );
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await _mapApi.post('/buildings', {
        'place_id': _selectedPlaceId,
        'code': code,
        'name': name,
        'latitude': lat,
        'longitude': lng,
        'floors': floors,
        'has_elevator': _hasElevator,
        'has_stairs': _hasStairs,
        if (_addressController.text.trim().isNotEmpty)
          'address': _addressController.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = 'Failed to save building: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _addressController.dispose();
    _floorsController.dispose();
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add building')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loadingPlaces)
              const Center(child: CircularProgressIndicator())
            else if (_places.isEmpty)
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
                        child: Text(p['name'] as String? ?? p['id'] as String),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _selectedPlaceId = value),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _codeController,
              decoration: const InputDecoration(labelText: 'Code'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _addressController,
              decoration: const InputDecoration(
                labelText: 'Address (optional)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _latController,
              decoration: const InputDecoration(labelText: 'Latitude'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _lngController,
              decoration: const InputDecoration(labelText: 'Longitude'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickOnMap,
              icon: const Icon(Icons.map),
              label: const Text('Pick on map'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _floorsController,
              decoration: const InputDecoration(labelText: 'Floors'),
              keyboardType: TextInputType.number,
            ),
            CheckboxListTile(
              title: const Text('Has elevator'),
              value: _hasElevator,
              onChanged: (value) =>
                  setState(() => _hasElevator = value ?? false),
            ),
            CheckboxListTile(
              title: const Text('Has stairs'),
              value: _hasStairs,
              onChanged: (value) => setState(() => _hasStairs = value ?? true),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: (_submitting || _places.isEmpty) ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save building'),
            ),
          ],
        ),
      ),
    );
  }
}

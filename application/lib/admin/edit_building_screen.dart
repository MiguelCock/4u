import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import 'location_picker_screen.dart';

/// Admin form to edit an existing `buildings` row (`PATCH /buildings/{id}`) -
/// mirrors `AddBuildingScreen` but pre-filled and without a place picker
/// (moving a building between places isn't supported here).
class EditBuildingScreen extends StatefulWidget {
  final Map<String, dynamic> building;

  const EditBuildingScreen({super.key, required this.building});

  @override
  State<EditBuildingScreen> createState() => _EditBuildingScreenState();
}

class _EditBuildingScreenState extends State<EditBuildingScreen> {
  final _mapApi = MapManagementApi();
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _floorsController;
  late final TextEditingController _latController;
  late final TextEditingController _lngController;
  late bool _hasElevator;
  late bool _hasStairs;
  late bool _isActive;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.building['name'] as String? ?? '',
    );
    _addressController = TextEditingController(
      text: widget.building['address'] as String? ?? '',
    );
    _floorsController = TextEditingController(
      text: (widget.building['floors'] as num?)?.toString() ?? '1',
    );
    _latController = TextEditingController(
      text: (widget.building['latitude'] as num?)?.toString() ?? '',
    );
    _lngController = TextEditingController(
      text: (widget.building['longitude'] as num?)?.toString() ?? '',
    );
    _hasElevator = widget.building['has_elevator'] as bool? ?? false;
    _hasStairs = widget.building['has_stairs'] as bool? ?? true;
    _isActive = widget.building['is_active'] as bool? ?? true;
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
          buildingsPlaceId: widget.building['place_id'] as String?,
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
    final name = _nameController.text.trim();
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    final floors = int.tryParse(_floorsController.text.trim()) ?? 1;
    if (name.isEmpty || lat == null || lng == null) {
      setState(() => _error = 'Name, latitude and longitude are required.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await _mapApi.patch('/buildings/${widget.building['id']}', {
        'name': name,
        'latitude': lat,
        'longitude': lng,
        'floors': floors,
        'has_elevator': _hasElevator,
        'has_stairs': _hasStairs,
        'is_active': _isActive,
        'address': _addressController.text.trim().isEmpty
            ? null
            : _addressController.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = 'Failed to update building: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
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
      appBar: AppBar(title: const Text('Edit building')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            SwitchListTile(
              title: const Text('Active'),
              value: _isActive,
              onChanged: (value) => setState(() => _isActive = value),
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
                  : const Text('Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import 'location_picker_screen.dart';

/// Admin form to edit an existing `places` row (`PATCH /places/{id}`) -
/// mirrors `AddPlaceScreen` but pre-filled and without a code field (code is
/// immutable once other rows may reference it).
class EditPlaceScreen extends StatefulWidget {
  final Map<String, dynamic> place;

  const EditPlaceScreen({super.key, required this.place});

  @override
  State<EditPlaceScreen> createState() => _EditPlaceScreenState();
}

class _EditPlaceScreenState extends State<EditPlaceScreen> {
  final _mapApi = MapManagementApi();
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _latController;
  late final TextEditingController _lngController;
  late bool _isActive;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.place['name'] as String? ?? '',
    );
    _addressController = TextEditingController(
      text: widget.place['address'] as String? ?? '',
    );
    _latController = TextEditingController(
      text: (widget.place['latitude'] as num?)?.toString() ?? '',
    );
    _lngController = TextEditingController(
      text: (widget.place['longitude'] as num?)?.toString() ?? '',
    );
    _isActive = widget.place['is_active'] as bool? ?? true;
  }

  Future<void> _pickOnMap() async {
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    final initial = (lat != null && lng != null)
        ? LatLng(lat, lng)
        : const LatLng(0, 0);
    final result = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) =>
            LocationPickerScreen(initialPosition: initial, showPlaces: true),
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
    if (name.isEmpty || lat == null || lng == null) {
      setState(() => _error = 'Name, latitude and longitude are required.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await _mapApi.patch('/places/${widget.place['id']}', {
        'name': name,
        'latitude': lat,
        'longitude': lng,
        'address': _addressController.text.trim().isEmpty
            ? null
            : _addressController.text.trim(),
        'is_active': _isActive,
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = 'Failed to update place: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit place')),
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

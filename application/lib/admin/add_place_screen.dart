import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import '../services/location_service.dart';
import 'location_picker_screen.dart';

/// Admin form to create a `places` row - the root of the place -> building ->
/// anchor point chain, previously only creatable by hand via SQL.
class AddPlaceScreen extends StatefulWidget {
  const AddPlaceScreen({super.key});

  @override
  State<AddPlaceScreen> createState() => _AddPlaceScreenState();
}

class _AddPlaceScreenState extends State<AddPlaceScreen> {
  final _mapApi = MapManagementApi();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  late final TextEditingController _latController;
  late final TextEditingController _lngController;
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
  }

  Future<void> _pickOnMap() async {
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    final initial = (lat != null && lng != null)
        ? LatLng(lat, lng)
        : const LatLng(0, 0);
    final result = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(initialPosition: initial),
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
      await _mapApi.post('/places', {
        'code': code,
        'name': name,
        'latitude': lat,
        'longitude': lng,
        if (_addressController.text.trim().isNotEmpty)
          'address': _addressController.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = 'Failed to save place: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _addressController.dispose();
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add place')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                  : const Text('Save place'),
            ),
          ],
        ),
      ),
    );
  }
}

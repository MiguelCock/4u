import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import 'capture_screen.dart' show kLocationTypes;
import 'location_picker_screen.dart';

const List<String> kAnchorPointStatuses = ['pending', 'verified', 'rejected'];

/// Admin form to edit an existing `anchor_points` row (`PATCH
/// /anchor-points/{id}`) - description, location type, status (verify
/// workflow), and position (move on map). Photos are managed separately via
/// `CapturePhotoScreen`.
class EditAnchorPointScreen extends StatefulWidget {
  final Map<String, dynamic> anchorPoint;

  const EditAnchorPointScreen({super.key, required this.anchorPoint});

  @override
  State<EditAnchorPointScreen> createState() => _EditAnchorPointScreenState();
}

class _EditAnchorPointScreenState extends State<EditAnchorPointScreen> {
  final _mapApi = MapManagementApi();
  late final TextEditingController _descriptionController;
  late LatLng _position;
  int? _locationTypeId;
  late String _status;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _descriptionController = TextEditingController(
      text: widget.anchorPoint['location_description'] as String? ?? '',
    );
    _position = LatLng(
      (widget.anchorPoint['latitude'] as num).toDouble(),
      (widget.anchorPoint['longitude'] as num).toDouble(),
    );
    _locationTypeId = widget.anchorPoint['location_type_id'] as int?;
    _status = widget.anchorPoint['status'] as String? ?? 'pending';
  }

  Future<void> _pickOnMap() async {
    final result = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialPosition: _position,
          showBuildings: true,
          showAnchorPoints: true,
          anchorPointsBuildingId: widget.anchorPoint['building_id'] as String?,
        ),
      ),
    );
    if (result != null) setState(() => _position = result);
  }

  Future<void> _submit() async {
    final description = _descriptionController.text.trim();
    if (description.isEmpty) {
      setState(() => _error = 'Description is required.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await _mapApi.patch('/anchor-points/${widget.anchorPoint['id']}', {
        'location_description': description,
        'latitude': _position.latitude,
        'longitude': _position.longitude,
        'location_type_id': _locationTypeId,
        'status': _status,
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = 'Failed to update anchor point: $e');
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
      appBar: AppBar(title: const Text('Edit anchor point')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description',
                helperText:
                    'Required - used as this point\'s name so it can be told apart from others.',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _locationTypeId,
              decoration: const InputDecoration(labelText: 'Location type'),
              items: kLocationTypes.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _locationTypeId = value),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: kAnchorPointStatuses
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (value) => setState(() => _status = value!),
            ),
            const SizedBox(height: 12),
            Text(
              'Location: ${_position.latitude.toStringAsFixed(6)}, ${_position.longitude.toStringAsFixed(6)}',
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickOnMap,
              icon: const Icon(Icons.map),
              label: const Text('Move on map'),
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

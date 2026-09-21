import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import 'capture_photo_screen.dart';
import 'capture_screen.dart' show kLocationTypes;
import 'location_picker_screen.dart';

const List<String> kAnchorPointStatuses = ['pending', 'verified', 'rejected'];

/// Admin form to edit an existing `anchor_points` row (`PATCH
/// /anchor-points/{id}`) - description, location type, status (verify
/// workflow), and position (move on map). Shows the point's captured photos
/// read-only so an admin has something to actually judge before verifying/
/// rejecting - full photo add/delete still happens in `CapturePhotoScreen`,
/// reachable here via "Manage photos".
class EditAnchorPointScreen extends StatefulWidget {
  final Map<String, dynamic> anchorPoint;

  const EditAnchorPointScreen({super.key, required this.anchorPoint});

  @override
  State<EditAnchorPointScreen> createState() => _EditAnchorPointScreenState();
}

class _EditAnchorPointScreenState extends State<EditAnchorPointScreen> {
  final _mapApi = MapManagementApi();
  final _aiTrainingApi = AiTrainingApi();
  late final TextEditingController _descriptionController;
  late LatLng _position;
  int? _locationTypeId;
  late String _status;
  bool _submitting = false;
  String? _error;

  List<Map<String, dynamic>> _photos = [];
  bool _loadingPhotos = true;

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
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    try {
      final result = await _mapApi.get(
        '/anchor-points/${widget.anchorPoint['id']}/photos',
      );
      if (!mounted) return;
      if (result is List) {
        setState(() => _photos = result.cast<Map<String, dynamic>>());
      }
    } on ApiException {
      // Photo preview is a convenience for the verify decision, not
      // required to edit the rest of the form - fail silently.
    } finally {
      if (mounted) setState(() => _loadingPhotos = false);
    }
  }

  Future<void> _managePhotos() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CapturePhotoScreen(
          anchorPointId: widget.anchorPoint['id'] as String,
          anchorPointDescription:
              widget.anchorPoint['location_description'] as String? ??
              widget.anchorPoint['id'] as String,
        ),
      ),
    );
    _loadPhotos();
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
    } on ApiException catch (e) {
      setState(() {
        _error = 'Failed to update anchor point: $e';
        _submitting = false;
      });
      return;
    }

    // Only confirmed-good anchor points enter the searchable index - index
    // right after a successful verify, not on every save. Indexing failure
    // doesn't roll back the verify (which already succeeded); it stays on
    // this screen with an inline error instead of popping, since re-tapping
    // Save safely retries (Qdrant upserts by photo id are idempotent).
    if (_status == 'verified' && _photos.isNotEmpty) {
      try {
        await _aiTrainingApi.post('/index_anchor', {
          'anchor_point_id': widget.anchorPoint['id'],
          'latitude': _position.latitude,
          'longitude': _position.longitude,
          'building_id': widget.anchorPoint['building_id'],
          'photos': _photos
              .map(
                (p) => {
                  'photo_id': p['id'],
                  'image_url': p['image_url'],
                  'heading': p['heading'],
                },
              )
              .toList(),
        });
      } on ApiException catch (e) {
        setState(() {
          _error = 'Verified, but indexing into search failed: $e';
          _submitting = false;
        });
        return;
      }
    } else if (_status != 'verified') {
      // Un-verifying (back to pending, or rejected) must not leave a
      // downgraded point searchable - best-effort like admin_home_screen's
      // delete cleanup, unlike the verify branch above: this doesn't block
      // saving the status change, and is safe to call even if the point was
      // never actually indexed (a filter-delete with no matches is a no-op).
      try {
        await _aiTrainingApi.delete(
          '/index_anchor/${widget.anchorPoint['id']}',
        );
      } on ApiException {
        // Best-effort.
      }
    }

    if (mounted) Navigator.of(context).pop(true);
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
            Text('Photos', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (_loadingPhotos)
              const Center(child: CircularProgressIndicator())
            else if (_photos.isEmpty)
              const Text(
                'No photos captured yet.',
                style: TextStyle(color: Colors.red),
              )
            else
              SizedBox(
                height: 72,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _photos.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    final url = _photos[index]['image_url'] as String?;
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: url != null
                          ? Image.network(
                              url,
                              width: 72,
                              height: 72,
                              fit: BoxFit.cover,
                            )
                          : Container(
                              width: 72,
                              height: 72,
                              color: Colors.grey.shade300,
                            ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _managePhotos,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text('Manage photos (${_photos.length})'),
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

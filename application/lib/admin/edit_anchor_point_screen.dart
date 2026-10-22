import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import 'capture_photo_screen.dart';
import '../services/location_types.dart';
import 'location_picker_screen.dart';
import '../services/anchor_indexing.dart';
import '../services/api_error_messages.dart';
import '../services/destinations.dart';
import '../widgets/floor_field.dart';
import '../widgets/location_type_field.dart';

const List<String> kAnchorPointStatuses = ['pending', 'verified', 'rejected'];

/// `kAnchorPointStatuses`' values are the stable storage keys - this maps
/// one to its localized label without changing what's actually stored.
String anchorStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'pending' => l10n.commonStatusPending,
    'verified' => l10n.commonStatusVerified,
    'rejected' => l10n.commonStatusRejected,
    _ => status,
  };
}

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
  late final TextEditingController _surfaceController;
  late LatLng _position;
  late final LatLng _originalPosition;
  late int _floor;
  int _buildingFloors = 1;
  bool _photosLoadFailed = false;
  int? _locationTypeId;
  late String _status;
  bool _indoor = true;
  String? _lighting;
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
    _originalPosition = _position;
    _floor = widget.anchorPoint['floor'] as int? ?? 0;
    _locationTypeId = widget.anchorPoint['location_type_id'] as int?;
    _status = widget.anchorPoint['status'] as String? ?? 'pending';
    final metadata =
        widget.anchorPoint['metadata'] as Map<String, dynamic>? ?? {};
    _indoor = metadata['indoor'] as bool? ?? true;
    _lighting = metadata['lighting'] as String?;
    _surfaceController = TextEditingController(
      text: metadata['surface'] as String? ?? '',
    );
    _loadPhotos();
    _loadBuildingFloors();
  }

  /// For the floor dropdown; best effort (the point's own floor is always
  /// offered).
  Future<void> _loadBuildingFloors() async {
    try {
      final building = await _mapApi.get(
        '/buildings/${widget.anchorPoint['building_id']}',
      );
      if (!mounted || building is! Map) return;
      setState(() => _buildingFloors = building['floors'] as int? ?? 1);
    } on ApiException {
      // Keep the default.
    }
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
      // Not needed to edit the rest of the form, but saving a *verified*
      // point re-sends its photos to search, so _submit checks this.
      if (mounted) setState(() => _photosLoadFailed = true);
    } finally {
      if (mounted) setState(() => _loadingPhotos = false);
    }
  }

  Future<void> _managePhotos() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CapturePhotoScreen(
          anchorPointId: widget.anchorPoint['id'] as String,
          anchorPointDescription: anchorDisplayName(
            AppLocalizations.of(context)!,
            widget.anchorPoint,
          ),
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
    final l10n = AppLocalizations.of(context)!;
    final description = _descriptionController.text.trim();
    if (description.isEmpty && descriptionRequiredFor(_locationTypeId)) {
      setState(() => _error = l10n.commonErrorDescriptionRequired);
      return;
    }
    if (_status == 'verified') {
      // Silently skipping indexing used to leave a "verified" point the
      // camera could never recognise.
      if (_photosLoadFailed) {
        setState(() => _error = l10n.editAnchorErrorPhotosUnavailable);
        return;
      }
      if (!_loadingPhotos && _photos.isEmpty) {
        setState(() => _error = l10n.editAnchorErrorVerifyNeedsPhoto);
        return;
      }
    }
    final moved = _position != _originalPosition;

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final surface = _surfaceController.text.trim();
      await _mapApi.patch('/anchor-points/${widget.anchorPoint['id']}', {
        'location_description': description.isEmpty ? null : description,
        'latitude': _position.latitude,
        'longitude': _position.longitude,
        // The phone's GPS altitude was for where the point was captured.
        if (moved) 'altitude': null,
        'floor': _floor,
        'location_type_id': _locationTypeId,
        'status': _status,
        'metadata': {
          'indoor': _indoor,
          'lighting': _lighting,
          'surface': surface.isEmpty ? null : surface,
        },
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = l10n.editAnchorErrorUpdateFailed(
          friendlyApiErrorMessage(context, e),
        );
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
        await _aiTrainingApi.post(
          '/index_anchor',
          indexAnchorPayload(
            anchorPointId: widget.anchorPoint['id'] as String,
            latitude: _position.latitude,
            longitude: _position.longitude,
            buildingId: widget.anchorPoint['building_id'] as String?,
            photos: _photos,
          ),
        );
      } on ApiException catch (e) {
        if (!mounted) return;
        setState(() {
          _error = l10n.editAnchorErrorIndexingFailed(
            friendlyApiErrorMessage(context, e),
          );
          _submitting = false;
        });
        return;
      }
    } else if (_status != 'verified') {
      // Un-verifying (back to pending, or rejected) must not leave a
      // downgraded point searchable. Deliberately blocking on failure, same
      // as the verify branch above - an earlier best-effort version swallowed
      // ApiException here, which meant a real failure would look identical to
      // nothing happening at all. Safe to call even if the point was never
      // actually indexed (a filter-delete with no matches is a no-op).
      try {
        await _aiTrainingApi.delete(
          '/index_anchor/${widget.anchorPoint['id']}',
        );
      } on ApiException catch (e) {
        if (!mounted) return;
        setState(() {
          _error = l10n.editAnchorErrorUnindexFailed(
            friendlyApiErrorMessage(context, e),
          );
          _submitting = false;
        });
        return;
      }
    }

    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _surfaceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.editAnchorTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _descriptionController,
                decoration: InputDecoration(
                  labelText: l10n.commonDescriptionLabel,
                  helperText: descriptionRequiredFor(_locationTypeId)
                      ? l10n.commonDescriptionHelper
                      : l10n.commonDescriptionHelperOptional,
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: 12),
              FloorField(
                value: _floor,
                buildingFloors: _buildingFloors,
                onChanged: (floor) => setState(() => _floor = floor),
              ),
              const SizedBox(height: 12),
              LocationTypeField(
                value: _locationTypeId,
                onChanged: (value) => setState(() => _locationTypeId = value),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.commonIndoorLocationLabel),
                value: _indoor,
                onChanged: (value) => setState(() => _indoor = value),
              ),
              DropdownButtonFormField<String?>(
                initialValue: _lighting,
                decoration: InputDecoration(
                  labelText: l10n.commonLightingLabel,
                ),
                items: [
                  DropdownMenuItem(
                    value: null,
                    child: Text(l10n.commonLightingNotSet),
                  ),
                  DropdownMenuItem(
                    value: 'bright',
                    child: Text(l10n.commonLightingBright),
                  ),
                  DropdownMenuItem(
                    value: 'moderate',
                    child: Text(l10n.commonLightingModerate),
                  ),
                  DropdownMenuItem(
                    value: 'dim',
                    child: Text(l10n.commonLightingDim),
                  ),
                ],
                onChanged: (value) => setState(() => _lighting = value),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _surfaceController,
                decoration: InputDecoration(
                  labelText: l10n.commonSurfaceLabel,
                  helperText: l10n.commonSurfaceHelper,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.editAnchorPhotosLabel,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              if (_loadingPhotos)
                const Center(child: CircularProgressIndicator())
              else if (_photos.isEmpty)
                Text(
                  l10n.editAnchorNoPhotosYet,
                  style: const TextStyle(color: Colors.red),
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
                label: Text(l10n.editAnchorManagePhotosButton(_photos.length)),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: InputDecoration(
                  labelText: l10n.editAnchorStatusLabel,
                ),
                items: kAnchorPointStatuses
                    .map(
                      (s) => DropdownMenuItem(
                        value: s,
                        child: Text(anchorStatusLabel(l10n, s)),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _status = value!),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.editAnchorLocationText(
                  _position.latitude.toStringAsFixed(6),
                  _position.longitude.toStringAsFixed(6),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _pickOnMap,
                icon: const Icon(Icons.map),
                label: Text(l10n.editAnchorMoveOnMapButton),
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
                    : Text(l10n.commonSaveChanges),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';
import 'capture_photo_screen.dart';
import 'location_picker_screen.dart';
import '../services/api_error_messages.dart';
import '../services/destinations.dart';
import '../services/location_types.dart';
import '../widgets/floor_field.dart';
import '../widgets/location_type_field.dart';

/// Creates a new `anchor_points` row (position + description only — no
/// photos live here anymore, since one physical point ends up with ~4-8
/// photos). On success, hands off to `CapturePhotoScreen` to take them.
class CaptureScreen extends StatefulWidget {
  /// Pre-selects this university/building if the admin opened this form
  /// while already filtered to one (`AdminHomeScreen`'s
  /// `_anchorPointsBuildingFilterId`, plus that building's own `place_id`)
  /// - falls back to the first fetched place/building otherwise, same as
  /// before.
  final String? initialPlaceId;
  final String? initialBuildingId;

  const CaptureScreen({super.key, this.initialPlaceId, this.initialBuildingId});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _mapApi = MapManagementApi();
  final _locationService = LocationService();
  final _descriptionController = TextEditingController();
  final _surfaceController = TextEditingController();

  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildingsAll = [];
  List<Map<String, dynamic>> _buildings = [];
  String? _selectedPlaceId;
  String? _selectedBuildingId;
  // Hallway: most points an admin adds while filling in a route are
  // in-between ones, which don't need a description.
  int _selectedLocationTypeId = 10;
  int _floor = 0;
  LatLng? _pickedPosition;
  bool _indoor = true;
  String? _lighting;
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
        final initialPlaceId = widget.initialPlaceId;
        if (initialPlaceId != null &&
            _places.any((p) => p['id'] == initialPlaceId)) {
          _selectedPlaceId = initialPlaceId;
        } else if (_places.isNotEmpty) {
          _selectedPlaceId = _places.first['id'] as String?;
        }
        _applyBuildingFilter(preferredBuildingId: widget.initialBuildingId);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = AppLocalizations.of(
          context,
        )!.captureErrorLoadFailed(friendlyApiErrorMessage(context, e)),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _selectedBuildingFloors =>
      _buildings.firstWhere(
            (b) => b['id'] == _selectedBuildingId,
            orElse: () => const {},
          )['floors']
          as int? ??
      1;

  void _applyBuildingFilter({String? preferredBuildingId}) {
    _buildings = _buildingsAll
        .where((b) => b['place_id'] == _selectedPlaceId)
        .toList();
    if (preferredBuildingId != null &&
        _buildings.any((b) => b['id'] == preferredBuildingId)) {
      _selectedBuildingId = preferredBuildingId;
    } else {
      _selectedBuildingId = _buildings.isNotEmpty
          ? _buildings.first['id'] as String?
          : null;
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
          buildingsPlaceId: _selectedPlaceId,
          anchorPointsBuildingId: _selectedBuildingId,
        ),
      ),
    );
    if (result != null) setState(() => _pickedPosition = result);
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final position = _locationService.lastPosition;
    final description = _descriptionController.text.trim();

    if (_selectedPlaceId == null) {
      setState(() => _error = l10n.commonErrorSelectUniversity);
      return;
    }
    if (_selectedBuildingId == null) {
      setState(() => _error = l10n.captureErrorSelectBuilding);
      return;
    }
    if (description.isEmpty &&
        descriptionRequiredFor(_selectedLocationTypeId)) {
      setState(() => _error = l10n.commonErrorDescriptionRequired);
      return;
    }
    if (position == null && _pickedPosition == null) {
      setState(() => _error = l10n.captureErrorLocationUnavailable);
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final surface = _surfaceController.text.trim();
      final result = await _mapApi.post('/anchor-points', {
        'building_id': _selectedBuildingId,
        'location_type_id': _selectedLocationTypeId,
        'latitude': _pickedPosition?.latitude ?? position!.latitude,
        'longitude': _pickedPosition?.longitude ?? position!.longitude,
        // The phone's GPS altitude only means something when the point is
        // where the phone is, not a spot picked on the map.
        'altitude': _pickedPosition == null ? position?.altitude : null,
        'floor': _floor,
        'location_description': description.isEmpty ? null : description,
        'metadata': {
          'indoor': _indoor,
          'lighting': _lighting,
          'surface': surface.isEmpty ? null : surface,
        },
      });
      final id = (result as List).first['id'] as String;
      // Unnamed in-between points are announced by their type instead.
      final displayName = description.isNotEmpty
          ? description
          : locationTypeLabel(l10n, kLocationTypes[_selectedLocationTypeId]!);

      if (!mounted) return;
      // The root ScaffoldMessenger keeps this visible over the photo screen
      // pushed right after, so the confirmation isn't lost in the transition.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 5),
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.captureSnackbarCreated(displayName),
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CapturePhotoScreen(
            anchorPointId: id,
            anchorPointDescription: displayName,
          ),
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = AppLocalizations.of(
          context,
        )!.captureErrorSaveFailed(friendlyApiErrorMessage(context, e)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = AppLocalizations.of(
          context,
        )!.captureErrorSaveFailed(friendlyApiErrorMessage(context, e)),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
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
      appBar: AppBar(title: Text(l10n.captureTitle)),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_places.isEmpty)
                      Text(
                        l10n.commonNoUniversitiesYetHint,
                        style: const TextStyle(color: Colors.red),
                      )
                    else
                      DropdownButtonFormField<String>(
                        initialValue: _selectedPlaceId,
                        decoration: InputDecoration(
                          labelText: l10n.commonUniversityLabel,
                        ),
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
                      Text(
                        l10n.captureNoBuildingsHint,
                        style: const TextStyle(color: Colors.red),
                      )
                    else if (_buildings.isNotEmpty)
                      DropdownButtonFormField<String>(
                        initialValue: _selectedBuildingId,
                        decoration: InputDecoration(
                          labelText: l10n.commonBuildingLabel,
                        ),
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
                        onChanged: (value) => setState(() {
                          _selectedBuildingId = value;
                          _floor = 0;
                        }),
                      ),
                    const SizedBox(height: 12),
                    FloorField(
                      value: _floor,
                      buildingFloors: _selectedBuildingFloors,
                      onChanged: (floor) => setState(() => _floor = floor),
                    ),
                    const SizedBox(height: 12),
                    LocationTypeField(
                      value: _selectedLocationTypeId,
                      onChanged: (value) =>
                          setState(() => _selectedLocationTypeId = value),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _descriptionController,
                      decoration: InputDecoration(
                        labelText: l10n.commonDescriptionLabel,
                        helperText:
                            descriptionRequiredFor(_selectedLocationTypeId)
                            ? l10n.commonDescriptionHelper
                            : l10n.commonDescriptionHelperOptional,
                        helperMaxLines: 3,
                      ),
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
                      _pickedPosition != null
                          ? l10n.captureLocationPickedText(
                              _pickedPosition!.latitude.toStringAsFixed(6),
                              _pickedPosition!.longitude.toStringAsFixed(6),
                            )
                          : _locationService.lastPosition != null
                          ? l10n.captureLocationGpsText(
                              _locationService.lastPosition!.latitude
                                  .toStringAsFixed(6),
                              _locationService.lastPosition!.longitude
                                  .toStringAsFixed(6),
                            )
                          : l10n.captureLocationUnavailableText,
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _pickOnMap,
                      icon: const Icon(Icons.map),
                      label: Text(l10n.commonPickOnMap),
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
                          : Text(l10n.captureSubmitButton),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

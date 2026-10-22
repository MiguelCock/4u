import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';
import 'capture_photo_screen.dart';
import 'location_picker_screen.dart';
import '../services/api_error_messages.dart';
import '../services/destinations.dart';

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
  10: 'hallway',
  11: 'ramp',
  12: 'outdoor_path',
  13: 'parking',
  14: 'lobby',
  15: 'auditorium',
  16: 'courtyard',
  17: 'crosswalk',
  18: 'bus_stop',
  9: 'other',
};

/// What admin screens call an anchor point: its description, or, for an
/// unnamed in-between point, its location type plus a short id so several
/// "Hallway" points can still be told apart.
String anchorDisplayName(AppLocalizations l10n, Map<String, dynamic>? point) {
  final description = (point?['location_description'] as String? ?? '').trim();
  if (description.isNotEmpty) return description;
  final id = point?['id'] as String? ?? '?';
  final type = kLocationTypes[point?['location_type_id'] as int?];
  final shortId = id.length > 4 ? id.substring(0, 4) : id;
  return type == null ? shortId : '${locationTypeLabel(l10n, type)} · $shortId';
}

/// `kLocationTypes`' values are the stable storage keys sent to/from the
/// backend - this maps one to the localized label shown in dropdowns,
/// without changing what's actually stored.
String locationTypeLabel(AppLocalizations l10n, String type) {
  return switch (type) {
    'entrance' => l10n.locationTypeEntrance,
    'intersection' => l10n.locationTypeIntersection,
    'elevator' => l10n.locationTypeElevator,
    'stairwell' => l10n.locationTypeStairwell,
    'classroom' => l10n.locationTypeClassroom,
    'office' => l10n.locationTypeOffice,
    'restroom' => l10n.locationTypeRestroom,
    'cafeteria' => l10n.locationTypeCafeteria,
    'hallway' => l10n.locationTypeHallway,
    'ramp' => l10n.locationTypeRamp,
    'outdoor_path' => l10n.locationTypeOutdoorPath,
    'parking' => l10n.locationTypeParking,
    'lobby' => l10n.locationTypeLobby,
    'auditorium' => l10n.locationTypeAuditorium,
    'courtyard' => l10n.locationTypeCourtyard,
    'crosswalk' => l10n.locationTypeCrosswalk,
    'bus_stop' => l10n.locationTypeBusStop,
    'other' => l10n.locationTypeOther,
    _ => type,
  };
}

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
      setState(
        () => _error = AppLocalizations.of(
          context,
        )!.captureErrorLoadFailed(friendlyApiErrorMessage(context, e)),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

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
        'altitude': position?.altitude,
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
      setState(
        () => _error = AppLocalizations.of(
          context,
        )!.captureErrorSaveFailed(friendlyApiErrorMessage(context, e)),
      );
    } catch (e) {
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
                        onChanged: (value) =>
                            setState(() => _selectedBuildingId = value),
                      ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: _selectedLocationTypeId,
                      decoration: InputDecoration(
                        labelText: l10n.commonLocationTypeLabel,
                      ),
                      items: kLocationTypes.entries
                          .map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(locationTypeLabel(l10n, e.value)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _selectedLocationTypeId = value!),
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

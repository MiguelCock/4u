import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';

/// Dropdown-based fallback/precision flow for creating an anchor-point
/// connection - mirrors the map-tap flow in `ConnectAnchorPointsScreen` but
/// without needing to be looking at the map, and lets an admin override the
/// auto-computed straight-line distance when the real walking distance
/// differs (a bend in a corridor, a floor change via elevator/stairs).
class AddConnectionScreen extends StatefulWidget {
  const AddConnectionScreen({super.key});

  @override
  State<AddConnectionScreen> createState() => _AddConnectionScreenState();
}

class _AddConnectionScreenState extends State<AddConnectionScreen> {
  final _mapApi = MapManagementApi();
  final _distanceController = TextEditingController();
  final _notesController = TextEditingController();

  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildingsAll = [];
  List<Map<String, dynamic>> _anchorPointsAll = [];
  String? _selectedPlaceId;
  String? _selectedBuildingId;
  String? _anchorPointAId;
  String? _anchorPointBId;
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
        _mapApi.get('/anchor-points'),
      ]);
      if (!mounted) return;
      setState(() {
        _places = (results[0] as List).cast<Map<String, dynamic>>();
        _buildingsAll = (results[1] as List).cast<Map<String, dynamic>>();
        _anchorPointsAll = (results[2] as List).cast<Map<String, dynamic>>();
        if (_places.isNotEmpty) {
          _selectedPlaceId = _places.first['id'] as String?;
        }
      });
    } on ApiException catch (e) {
      setState(
        () => _error = AppLocalizations.of(
          context,
        )!.commonErrorLoadDataFailed(e.toString()),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _buildingsInPlace =>
      _buildingsAll.where((b) => b['place_id'] == _selectedPlaceId).toList();

  List<Map<String, dynamic>> get _anchorPointsInScope {
    final buildingIds = _selectedBuildingId != null
        ? {_selectedBuildingId!}
        : _buildingsInPlace.map((b) => b['id'] as String).toSet();
    return _anchorPointsAll
        .where((p) => buildingIds.contains(p['building_id']))
        .toList();
  }

  String _label(Map<String, dynamic> point) =>
      point['location_description'] as String? ?? point['id'] as String;

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      setState(() => _error = l10n.commonNotSignedIn);
      return;
    }
    if (_anchorPointAId == null || _anchorPointBId == null) {
      setState(() => _error = l10n.addConnectionErrorSelectBoth);
      return;
    }
    if (_anchorPointAId == _anchorPointBId) {
      setState(() => _error = l10n.addConnectionErrorSelectDifferent);
      return;
    }

    final distance = double.tryParse(_distanceController.text.trim());

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await _mapApi.post('/anchor-point-connections', {
        'anchor_point_a_id': _anchorPointAId,
        'anchor_point_b_id': _anchorPointBId,
        'distance_meters': ?distance,
        if (_notesController.text.trim().isNotEmpty)
          'notes': _notesController.text.trim(),
        'created_by': userId,
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = l10n.addConnectionErrorSaveFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _distanceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final anchorPoints = _anchorPointsInScope;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.addConnectionTitle)),
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
                          _selectedBuildingId = null;
                          _anchorPointAId = null;
                          _anchorPointBId = null;
                        }),
                      ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      initialValue: _selectedBuildingId,
                      decoration: InputDecoration(
                        labelText: l10n.addConnectionBuildingFilterLabel,
                      ),
                      items: [
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text(l10n.commonAllBuildings),
                        ),
                        ..._buildingsInPlace.map(
                          (b) => DropdownMenuItem<String?>(
                            value: b['id'] as String,
                            child: Text(
                              b['name'] as String? ?? b['id'] as String,
                            ),
                          ),
                        ),
                      ],
                      onChanged: (value) => setState(() {
                        _selectedBuildingId = value;
                        _anchorPointAId = null;
                        _anchorPointBId = null;
                      }),
                    ),
                    const SizedBox(height: 12),
                    if (anchorPoints.isEmpty)
                      Text(
                        l10n.addConnectionNoAnchorPointsInScope,
                        style: const TextStyle(color: Colors.red),
                      )
                    else ...[
                      DropdownButtonFormField<String>(
                        initialValue: _anchorPointAId,
                        decoration: InputDecoration(
                          labelText: l10n.addConnectionAnchorPointALabel,
                        ),
                        items: anchorPoints
                            .map(
                              (p) => DropdownMenuItem(
                                value: p['id'] as String,
                                child: Text(_label(p)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) =>
                            setState(() => _anchorPointAId = value),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _anchorPointBId,
                        decoration: InputDecoration(
                          labelText: l10n.addConnectionAnchorPointBLabel,
                        ),
                        items: anchorPoints
                            .where((p) => p['id'] != _anchorPointAId)
                            .map(
                              (p) => DropdownMenuItem(
                                value: p['id'] as String,
                                child: Text(_label(p)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) =>
                            setState(() => _anchorPointBId = value),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: _distanceController,
                      decoration: InputDecoration(
                        labelText: l10n.addConnectionDistanceLabel,
                        helperText: l10n.addConnectionDistanceHelper,
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _notesController,
                      decoration: InputDecoration(
                        labelText: l10n.addConnectionNotesLabel,
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                    ],
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: (_submitting || anchorPoints.isEmpty)
                          ? null
                          : _submit,
                      child: _submitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l10n.addConnectionSaveButton),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

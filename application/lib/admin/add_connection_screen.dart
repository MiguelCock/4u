import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
      setState(() => _error = 'Failed to load data: $e');
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
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      setState(() => _error = 'Not signed in.');
      return;
    }
    if (_anchorPointAId == null || _anchorPointBId == null) {
      setState(() => _error = 'Select both anchor points.');
      return;
    }
    if (_anchorPointAId == _anchorPointBId) {
      setState(() => _error = 'Select two different anchor points.');
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
        if (distance != null) 'distance_meters': distance,
        if (_notesController.text.trim().isNotEmpty)
          'notes': _notesController.text.trim(),
        'created_by': userId,
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = 'Failed to save connection: $e');
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
    final anchorPoints = _anchorPointsInScope;
    return Scaffold(
      appBar: AppBar(title: const Text('Add connection')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_places.isEmpty)
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
                    decoration: const InputDecoration(
                      labelText: 'Building (optional filter)',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('All buildings'),
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
                    const Text(
                      'No anchor points in scope.',
                      style: TextStyle(color: Colors.red),
                    )
                  else ...[
                    DropdownButtonFormField<String>(
                      initialValue: _anchorPointAId,
                      decoration: const InputDecoration(
                        labelText: 'Anchor point A',
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
                      decoration: const InputDecoration(
                        labelText: 'Anchor point B',
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
                    decoration: const InputDecoration(
                      labelText: 'Distance in meters (optional)',
                      helperText:
                          'Leave blank to auto-compute straight-line distance.',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notesController,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
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
                        : const Text('Save connection'),
                  ),
                ],
              ),
            ),
    );
  }
}

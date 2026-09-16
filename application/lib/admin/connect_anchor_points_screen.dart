import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api_service.dart';
import '../services/map_tile_config.dart';

/// Map-tap flow for building the anchor-point walkability graph: tap one
/// anchor point, then another, to create a connection between them. The
/// second point stays selected after each connection so an admin can keep
/// tapping a third, fourth, etc. point to chain-connect along a corridor
/// without re-entering the flow.
class ConnectAnchorPointsScreen extends StatefulWidget {
  const ConnectAnchorPointsScreen({super.key});

  @override
  State<ConnectAnchorPointsScreen> createState() =>
      _ConnectAnchorPointsScreenState();
}

class _ConnectAnchorPointsScreenState extends State<ConnectAnchorPointsScreen> {
  final _mapApi = MapManagementApi();

  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildings = [];
  List<Map<String, dynamic>> _anchorPoints = [];
  List<Map<String, dynamic>> _connections = [];
  String? _selectedPlaceId;
  String? _selectedBuildingId;
  String? _selectedAnchorPointId;
  bool _loading = true;
  bool _connecting = false;
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
        _mapApi.get('/anchor-point-connections'),
      ]);
      if (!mounted) return;
      setState(() {
        _places = (results[0] as List).cast<Map<String, dynamic>>();
        _buildings = (results[1] as List).cast<Map<String, dynamic>>();
        _anchorPoints = (results[2] as List).cast<Map<String, dynamic>>();
        _connections = (results[3] as List).cast<Map<String, dynamic>>();
        if (_selectedPlaceId == null && _places.isNotEmpty) {
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
      _buildings.where((b) => b['place_id'] == _selectedPlaceId).toList();

  List<Map<String, dynamic>> get _visibleAnchorPoints {
    final buildingIds = _selectedBuildingId != null
        ? {_selectedBuildingId!}
        : _buildingsInPlace.map((b) => b['id'] as String).toSet();
    return _anchorPoints
        .where((p) => buildingIds.contains(p['building_id']))
        .toList();
  }

  Future<void> _onMarkerTap(Map<String, dynamic> point) async {
    final id = point['id'] as String;
    if (_selectedAnchorPointId == null) {
      setState(() => _selectedAnchorPointId = id);
      return;
    }
    if (_selectedAnchorPointId == id) {
      setState(() => _selectedAnchorPointId = null);
      return;
    }

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      setState(() => _error = 'Not signed in.');
      return;
    }

    final fromId = _selectedAnchorPointId!;
    setState(() {
      _connecting = true;
      _error = null;
    });

    try {
      await _mapApi.post('/anchor-point-connections', {
        'anchor_point_a_id': fromId,
        'anchor_point_b_id': id,
        'created_by': userId,
      });
      final fromDesc = _describePoint(fromId);
      final toDesc = _describePoint(id);
      final connectionsResult = await _mapApi.get('/anchor-point-connections');
      if (!mounted) return;
      setState(() {
        _connections = (connectionsResult as List).cast<Map<String, dynamic>>();
        _selectedAnchorPointId = id;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Connected $fromDesc ↔ $toDesc')));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.statusCode == 500 || e.statusCode == 409
                  ? 'Already connected (or a save error occurred).'
                  : 'Failed to connect: $e',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  String _describePoint(String id) {
    final point = _anchorPoints.firstWhere(
      (p) => p['id'] == id,
      orElse: () => {'id': id},
    );
    return point['location_description'] as String? ?? id;
  }

  List<Polyline> _connectionLines() {
    final byId = {for (final p in _anchorPoints) p['id'] as String: p};
    final visibleIds = _visibleAnchorPoints
        .map((p) => p['id'] as String)
        .toSet();
    final lines = <Polyline>[];
    for (final c in _connections) {
      final aId = c['anchor_point_a_id'] as String?;
      final bId = c['anchor_point_b_id'] as String?;
      if (aId == null || bId == null) continue;
      if (!visibleIds.contains(aId) || !visibleIds.contains(bId)) continue;
      final a = byId[aId];
      final b = byId[bId];
      final aLat = (a?['latitude'] as num?)?.toDouble();
      final aLng = (a?['longitude'] as num?)?.toDouble();
      final bLat = (b?['latitude'] as num?)?.toDouble();
      final bLng = (b?['longitude'] as num?)?.toDouble();
      if (aLat == null || aLng == null || bLat == null || bLng == null) {
        continue;
      }
      lines.add(
        Polyline(
          points: [LatLng(aLat, aLng), LatLng(bLat, bLng)],
          color: Colors.green,
          strokeWidth: 3,
        ),
      );
    }
    return lines;
  }

  List<Marker> _anchorMarkers() {
    return _visibleAnchorPoints
        .map((point) {
          final lat = (point['latitude'] as num?)?.toDouble();
          final lng = (point['longitude'] as num?)?.toDouble();
          if (lat == null || lng == null) {
            return null;
          }
          final selected = point['id'] == _selectedAnchorPointId;
          return Marker(
            point: LatLng(lat, lng),
            width: selected ? 50 : 36,
            height: selected ? 50 : 36,
            child: GestureDetector(
              onTap: _connecting ? null : () => _onMarkerTap(point),
              child: Icon(
                selected ? Icons.radio_button_checked : Icons.circle,
                color: selected ? Colors.blue : Colors.green,
                size: selected ? 32 : 16,
              ),
            ),
          );
        })
        .whereType<Marker>()
        .toList();
  }

  LatLng _initialCenter() {
    final points = _visibleAnchorPoints;
    if (points.isEmpty) return const LatLng(0, 0);
    final lat = (points.first['latitude'] as num).toDouble();
    final lng = (points.first['longitude'] as num).toDouble();
    return LatLng(lat, lng);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect on map')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _selectedPlaceId,
                          decoration: const InputDecoration(
                            labelText: 'Place',
                            isDense: true,
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
                            _selectedAnchorPointId = null;
                          }),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String?>(
                          initialValue: _selectedBuildingId,
                          decoration: const InputDecoration(
                            labelText: 'Building',
                            isDense: true,
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
                            _selectedAnchorPointId = null;
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _selectedAnchorPointId == null
                          ? 'Tap an anchor point to start a connection.'
                          : 'Tap another anchor point to connect '
                                '"${_describePoint(_selectedAnchorPointId!)}" to it.',
                    ),
                  ),
                ),
                Expanded(
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: _initialCenter(),
                      initialZoom: 18,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: kMapTileUrlTemplate,
                        userAgentPackageName: kMapUserAgentPackageName,
                      ),
                      PolylineLayer(polylines: _connectionLines()),
                      MarkerLayer(markers: _anchorMarkers()),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

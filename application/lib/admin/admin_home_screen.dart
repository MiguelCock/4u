import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api_service.dart';
import 'add_building_screen.dart';
import 'add_place_screen.dart';
import 'capture_screen.dart';

/// `admin`-role home screen: anchor points grouped by place then building,
/// with delete/refresh, plus entry points into `CaptureScreen`,
/// `AddPlaceScreen`, and `AddBuildingScreen`.
class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  final _mapApi = MapManagementApi();

  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildings = [];
  List<Map<String, dynamic>> _anchorPoints = [];
  bool _loading = true;
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
        _places = (results[0] as List? ?? []).cast<Map<String, dynamic>>();
        _buildings = (results[1] as List? ?? []).cast<Map<String, dynamic>>();
        _anchorPoints = (results[2] as List? ?? [])
            .cast<Map<String, dynamic>>();
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load data: $e';
        _loading = false;
      });
    }
  }

  Future<void> _deleteAnchorPoint(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete anchor point?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _mapApi.delete('/anchor-points/$id');
      await _loadData();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
      }
    }
  }

  /// Groups `_anchorPoints` by place, then building, each sorted by name -
  /// falls back to "Unknown place"/"Unknown building" for anchor points
  /// whose building/place reference doesn't resolve (e.g. stale data).
  List<Widget> _buildGroupedList() {
    final buildingsById = {for (final b in _buildings) b['id'] as String: b};
    final placesById = {for (final p in _places) p['id'] as String: p};

    final grouped = <String, Map<String, List<Map<String, dynamic>>>>{};
    final placeNames = <String, String>{};
    final buildingNames = <String, String>{};

    for (final point in _anchorPoints) {
      final buildingId = point['building_id'] as String?;
      final building = buildingId != null ? buildingsById[buildingId] : null;
      final placeId = building?['place_id'] as String?;
      final place = placeId != null ? placesById[placeId] : null;

      final placeKey = place?['id'] as String? ?? 'unknown-place';
      final buildingKey = building?['id'] as String? ?? 'unknown-building';
      placeNames[placeKey] = place?['name'] as String? ?? 'Unknown place';
      buildingNames[buildingKey] =
          building?['name'] as String? ?? 'Unknown building';

      grouped
          .putIfAbsent(placeKey, () => {})
          .putIfAbsent(buildingKey, () => [])
          .add(point);
    }

    final sortedPlaceKeys = grouped.keys.toList()
      ..sort((a, b) => placeNames[a]!.compareTo(placeNames[b]!));

    final widgets = <Widget>[];
    for (final placeKey in sortedPlaceKeys) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            placeNames[placeKey]!,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
        ),
      );

      final buildingsMap = grouped[placeKey]!;
      final sortedBuildingKeys = buildingsMap.keys.toList()
        ..sort((a, b) => buildingNames[a]!.compareTo(buildingNames[b]!));

      for (final buildingKey in sortedBuildingKeys) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 16, 4),
            child: Text(
              buildingNames[buildingKey]!,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        );

        for (final point in buildingsMap[buildingKey]!) {
          widgets.add(
            ListTile(
              leading: const Icon(Icons.location_pin),
              title: Text(
                point['location_description'] as String? ??
                    point['id'] as String,
              ),
              subtitle: Text('Status: ${point['status'] ?? 'unknown'}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete',
                onPressed: () => _deleteAnchorPoint(point['id'] as String),
              ),
            ),
          );
        }
      }
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _loadData,
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              final screen = value == 'place'
                  ? const AddPlaceScreen()
                  : const AddBuildingScreen();
              await Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => screen));
              _loadData();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'place', child: Text('Add place')),
              PopupMenuItem(value: 'building', child: Text('Add building')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const CaptureScreen()));
          _loadData();
        },
        child: const Icon(Icons.add_a_photo),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : RefreshIndicator(
              onRefresh: _loadData,
              child: _anchorPoints.isEmpty
                  ? ListView(
                      children: const [
                        Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(
                            child: Text('No anchor points captured yet.'),
                          ),
                        ),
                      ],
                    )
                  : ListView(children: _buildGroupedList()),
            ),
    );
  }
}

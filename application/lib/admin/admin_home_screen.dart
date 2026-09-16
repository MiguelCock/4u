import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api_service.dart';
import 'add_building_screen.dart';
import 'add_connection_screen.dart';
import 'add_place_screen.dart';
import 'capture_photo_screen.dart';
import 'capture_screen.dart';
import 'connect_anchor_points_screen.dart';
import 'edit_anchor_point_screen.dart';
import 'edit_building_screen.dart';
import 'edit_place_screen.dart';

/// `admin`-role home screen: four tabs (places / buildings / anchor points /
/// connections), each searchable, with edit and delete (cascade-impact
/// warning first) actions, plus entry points into the add/edit/capture/
/// connect screens.
class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen>
    with SingleTickerProviderStateMixin {
  final _mapApi = MapManagementApi();
  late final TabController _tabController;

  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildings = [];
  List<Map<String, dynamic>> _anchorPoints = [];
  List<Map<String, dynamic>> _photos = [];
  List<Map<String, dynamic>> _connections = [];
  bool _loading = true;
  String? _error;

  final _placeSearchController = TextEditingController();
  final _buildingSearchController = TextEditingController();
  final _anchorSearchController = TextEditingController();
  final _connectionSearchController = TextEditingController();
  String _placeQuery = '';
  String _buildingQuery = '';
  String _anchorQuery = '';
  String _connectionQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this)
      ..addListener(() => setState(() {}));
    _placeSearchController.addListener(
      () => setState(
        () => _placeQuery = _placeSearchController.text.trim().toLowerCase(),
      ),
    );
    _buildingSearchController.addListener(
      () => setState(
        () => _buildingQuery = _buildingSearchController.text
            .trim()
            .toLowerCase(),
      ),
    );
    _anchorSearchController.addListener(
      () => setState(
        () => _anchorQuery = _anchorSearchController.text.trim().toLowerCase(),
      ),
    );
    _connectionSearchController.addListener(
      () => setState(
        () => _connectionQuery = _connectionSearchController.text
            .trim()
            .toLowerCase(),
      ),
    );
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _placeSearchController.dispose();
    _buildingSearchController.dispose();
    _anchorSearchController.dispose();
    _connectionSearchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final results = await Future.wait([
        _mapApi.get('/places'),
        _mapApi.get('/buildings'),
        _mapApi.get('/anchor-points'),
        _mapApi.get('/anchor-point-photos'),
        _mapApi.get('/anchor-point-connections'),
      ]);
      if (!mounted) return;
      setState(() {
        _places = (results[0] as List? ?? []).cast<Map<String, dynamic>>();
        _buildings = (results[1] as List? ?? []).cast<Map<String, dynamic>>();
        _anchorPoints = (results[2] as List? ?? [])
            .cast<Map<String, dynamic>>();
        _photos = (results[3] as List? ?? []).cast<Map<String, dynamic>>();
        _connections = (results[4] as List? ?? []).cast<Map<String, dynamic>>();
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

  List<Map<String, dynamic>> _buildingsOf(String placeId) =>
      _buildings.where((b) => b['place_id'] == placeId).toList();

  List<Map<String, dynamic>> _anchorPointsOf(String buildingId) =>
      _anchorPoints.where((p) => p['building_id'] == buildingId).toList();

  List<Map<String, dynamic>> _photosOf(String anchorPointId) =>
      _photos.where((p) => p['anchor_point_id'] == anchorPointId).toList();

  List<Map<String, dynamic>> _connectionsOf(String anchorPointId) =>
      _connections
          .where(
            (c) =>
                c['anchor_point_a_id'] == anchorPointId ||
                c['anchor_point_b_id'] == anchorPointId,
          )
          .toList();

  Future<bool> _confirm({
    required String title,
    required String content,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
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
    return confirmed == true;
  }

  Future<void> _runDelete(Future<void> Function() action) async {
    try {
      await action();
      await _loadData();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
      }
    }
  }

  Future<void> _deletePlace(Map<String, dynamic> place) async {
    final buildings = _buildingsOf(place['id'] as String);
    final buildingIds = buildings.map((b) => b['id'] as String).toSet();
    final anchors = _anchorPoints
        .where((p) => buildingIds.contains(p['building_id']))
        .toList();
    final anchorIds = anchors.map((p) => p['id'] as String).toSet();
    final photoCount = _photos
        .where((ph) => anchorIds.contains(ph['anchor_point_id']))
        .length;
    final connectionCount = _connections
        .where(
          (c) =>
              anchorIds.contains(c['anchor_point_a_id']) ||
              anchorIds.contains(c['anchor_point_b_id']),
        )
        .length;

    final confirmed = await _confirm(
      title: 'Delete place?',
      content:
          'Deleting "${place['name']}" will also delete ${buildings.length} '
          'building(s), ${anchors.length} anchor point(s), $photoCount '
          'photo(s), and $connectionCount connection(s). This cannot be undone.',
    );
    if (!confirmed) return;
    await _runDelete(() => _mapApi.delete('/places/${place['id']}'));
  }

  Future<void> _deleteBuilding(Map<String, dynamic> building) async {
    final anchors = _anchorPointsOf(building['id'] as String);
    final anchorIds = anchors.map((p) => p['id'] as String).toSet();
    final photoCount = _photos
        .where((ph) => anchorIds.contains(ph['anchor_point_id']))
        .length;
    final connectionCount = _connections
        .where(
          (c) =>
              anchorIds.contains(c['anchor_point_a_id']) ||
              anchorIds.contains(c['anchor_point_b_id']),
        )
        .length;

    final confirmed = await _confirm(
      title: 'Delete building?',
      content:
          'Deleting "${building['name']}" will also delete ${anchors.length} '
          'anchor point(s), $photoCount photo(s), and $connectionCount '
          'connection(s). This cannot be undone.',
    );
    if (!confirmed) return;
    await _runDelete(() => _mapApi.delete('/buildings/${building['id']}'));
  }

  Future<void> _deleteAnchorPoint(Map<String, dynamic> point) async {
    final photoCount = _photosOf(point['id'] as String).length;
    final connectionCount = _connectionsOf(point['id'] as String).length;
    final confirmed = await _confirm(
      title: 'Delete anchor point?',
      content:
          'This will also delete $photoCount photo(s) and $connectionCount '
          'connection(s). This cannot be undone.',
    );
    if (!confirmed) return;
    await _runDelete(() => _mapApi.delete('/anchor-points/${point['id']}'));
  }

  Future<void> _deleteConnection(Map<String, dynamic> connection) async {
    final confirmed = await _confirm(
      title: 'Delete connection?',
      content: 'This cannot be undone.',
    );
    if (!confirmed) return;
    await _runDelete(
      () => _mapApi.delete('/anchor-point-connections/${connection['id']}'),
    );
  }

  Future<void> _editPlace(Map<String, dynamic> place) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EditPlaceScreen(place: place)),
    );
    if (changed == true) _loadData();
  }

  Future<void> _editBuilding(Map<String, dynamic> building) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EditBuildingScreen(building: building)),
    );
    if (changed == true) _loadData();
  }

  Future<void> _editAnchorPoint(Map<String, dynamic> point) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditAnchorPointScreen(anchorPoint: point),
      ),
    );
    if (changed == true) _loadData();
  }

  Future<void> _addPhoto(Map<String, dynamic> point) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CapturePhotoScreen(
          anchorPointId: point['id'] as String,
          anchorPointDescription:
              point['location_description'] as String? ?? point['id'] as String,
        ),
      ),
    );
    _loadData();
  }

  Widget _searchField(TextEditingController controller, String hint) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _placesTab() {
    final filtered =
        _places
            .where(
              (p) => (p['name'] as String? ?? '').toLowerCase().contains(
                _placeQuery,
              ),
            )
            .toList()
          ..sort(
            (a, b) => (a['name'] as String? ?? '').compareTo(
              b['name'] as String? ?? '',
            ),
          );

    return Column(
      children: [
        _searchField(_placeSearchController, 'Search places'),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No places found.'))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final place = filtered[index];
                    final buildingCount = _buildingsOf(
                      place['id'] as String,
                    ).length;
                    return ListTile(
                      leading: const Icon(Icons.flag, color: Colors.purple),
                      title: Text(
                        place['name'] as String? ?? place['id'] as String,
                      ),
                      subtitle: Text(
                        '$buildingCount building(s)'
                        '${(place['is_active'] as bool? ?? true) ? '' : ' - inactive'}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Edit',
                            onPressed: () => _editPlace(place),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Delete',
                            onPressed: () => _deletePlace(place),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildingsTab() {
    final placesById = {for (final p in _places) p['id'] as String: p};
    final filtered =
        _buildings
            .where(
              (b) => (b['name'] as String? ?? '').toLowerCase().contains(
                _buildingQuery,
              ),
            )
            .toList()
          ..sort(
            (a, b) => (a['name'] as String? ?? '').compareTo(
              b['name'] as String? ?? '',
            ),
          );

    return Column(
      children: [
        _searchField(_buildingSearchController, 'Search buildings'),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No buildings found.'))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final building = filtered[index];
                    final place = placesById[building['place_id']];
                    final anchorCount = _anchorPointsOf(
                      building['id'] as String,
                    ).length;
                    return ListTile(
                      leading: const Icon(
                        Icons.apartment,
                        color: Colors.orange,
                      ),
                      title: Text(
                        building['name'] as String? ?? building['id'] as String,
                      ),
                      subtitle: Text(
                        '${place?['name'] as String? ?? 'Unknown place'} · '
                        '$anchorCount anchor point(s)'
                        '${(building['is_active'] as bool? ?? true) ? '' : ' - inactive'}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Edit',
                            onPressed: () => _editBuilding(building),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Delete',
                            onPressed: () => _deleteBuilding(building),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _anchorPointsTab() {
    final buildingsById = {for (final b in _buildings) b['id'] as String: b};
    final filtered =
        _anchorPoints
            .where(
              (p) => (p['location_description'] as String? ?? '')
                  .toLowerCase()
                  .contains(_anchorQuery),
            )
            .toList()
          ..sort(
            (a, b) => (a['location_description'] as String? ?? '').compareTo(
              b['location_description'] as String? ?? '',
            ),
          );

    return Column(
      children: [
        _searchField(_anchorSearchController, 'Search anchor points'),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No anchor points found.'))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final point = filtered[index];
                    final building = buildingsById[point['building_id']];
                    final photos = _photosOf(point['id'] as String);
                    final thumbUrl = photos.isNotEmpty
                        ? photos.first['image_url'] as String?
                        : null;
                    return ListTile(
                      leading: thumbUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.network(
                                thumbUrl,
                                width: 40,
                                height: 40,
                                fit: BoxFit.cover,
                              ),
                            )
                          : const Icon(Icons.location_pin, color: Colors.green),
                      title: Text(
                        point['location_description'] as String? ??
                            point['id'] as String,
                      ),
                      subtitle: Text(
                        '${building?['name'] as String? ?? 'Unknown building'} · '
                        'Status: ${point['status'] ?? 'unknown'} · '
                        '${photos.length} photo(s)',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.add_a_photo_outlined),
                            tooltip: 'Add photo',
                            onPressed: () => _addPhoto(point),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Edit',
                            onPressed: () => _editAnchorPoint(point),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Delete',
                            onPressed: () => _deleteAnchorPoint(point),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _connectionsTab() {
    final anchorPointsById = {
      for (final p in _anchorPoints) p['id'] as String: p,
    };
    final buildingsById = {for (final b in _buildings) b['id'] as String: b};

    String describe(String? anchorPointId) {
      final point = anchorPointsById[anchorPointId];
      return point?['location_description'] as String? ?? anchorPointId ?? '?';
    }

    final filtered = _connections.where((c) {
      final aDesc = describe(c['anchor_point_a_id'] as String?).toLowerCase();
      final bDesc = describe(c['anchor_point_b_id'] as String?).toLowerCase();
      return aDesc.contains(_connectionQuery) ||
          bDesc.contains(_connectionQuery);
    }).toList();

    return Column(
      children: [
        _searchField(_connectionSearchController, 'Search connections'),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No connections found.'))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final connection = filtered[index];
                    final aPoint =
                        anchorPointsById[connection['anchor_point_a_id']];
                    final bPoint =
                        anchorPointsById[connection['anchor_point_b_id']];
                    final aBuilding = buildingsById[aPoint?['building_id']];
                    final bBuilding = buildingsById[bPoint?['building_id']];
                    final distance = (connection['distance_meters'] as num?)
                        ?.toStringAsFixed(1);
                    return ListTile(
                      leading: const Icon(Icons.timeline, color: Colors.teal),
                      title: Text(
                        '${describe(connection['anchor_point_a_id'] as String?)} '
                        '↔ ${describe(connection['anchor_point_b_id'] as String?)}',
                      ),
                      subtitle: Text(
                        '${aBuilding?['name'] as String? ?? 'Unknown'} / '
                        '${bBuilding?['name'] as String? ?? 'Unknown'}'
                        '${distance != null ? ' · ${distance}m' : ''}',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete',
                        onPressed: () => _deleteConnection(connection),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget? _fab() {
    switch (_tabController.index) {
      case 0:
        return FloatingActionButton(
          tooltip: 'Add place',
          onPressed: () async {
            await Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AddPlaceScreen()));
            _loadData();
          },
          child: const Icon(Icons.add),
        );
      case 1:
        return FloatingActionButton(
          tooltip: 'Add building',
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AddBuildingScreen()),
            );
            _loadData();
          },
          child: const Icon(Icons.add),
        );
      case 2:
        return FloatingActionButton(
          tooltip: 'New anchor point',
          onPressed: () async {
            await Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const CaptureScreen()));
            _loadData();
          },
          child: const Icon(Icons.add_a_photo),
        );
      default:
        return FloatingActionButton(
          tooltip: 'Connect on map',
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const ConnectAnchorPointsScreen(),
              ),
            );
            _loadData();
          },
          child: const Icon(Icons.timeline),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Places'),
            Tab(text: 'Buildings'),
            Tab(text: 'Anchor points'),
            Tab(text: 'Connections'),
          ],
        ),
        actions: [
          if (_tabController.index == 3)
            IconButton(
              icon: const Icon(Icons.list_alt),
              tooltip: 'Add connection (form)',
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AddConnectionScreen(),
                  ),
                );
                _loadData();
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _loadData,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      floatingActionButton: _fab(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : RefreshIndicator(
              onRefresh: _loadData,
              child: TabBarView(
                controller: _tabController,
                children: [
                  _placesTab(),
                  _buildingsTab(),
                  _anchorPointsTab(),
                  _connectionsTab(),
                ],
              ),
            ),
    );
  }
}

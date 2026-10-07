import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import 'add_building_screen.dart';
import 'add_connection_screen.dart';
import 'add_place_screen.dart';
import 'capture_photo_screen.dart';
import 'capture_screen.dart';
import 'connect_anchor_points_screen.dart';
import 'edit_anchor_point_screen.dart'
    show EditAnchorPointScreen, anchorStatusLabel;
import 'edit_building_screen.dart';
import 'edit_place_screen.dart';
import 'sessions_screen.dart';
import '../user/settings_screen.dart';

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
  final _aiTrainingApi = AiTrainingApi();
  final _userApi = UserManagementApi();
  late final TabController _tabController;

  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildings = [];
  List<Map<String, dynamic>> _anchorPoints = [];
  List<Map<String, dynamic>> _photos = [];
  List<Map<String, dynamic>> _connections = [];
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;
  String? _error;
  bool _usersLoaded = false;
  String? _usersError;

  final _placeSearchController = TextEditingController();
  final _buildingSearchController = TextEditingController();
  final _anchorSearchController = TextEditingController();
  final _connectionSearchController = TextEditingController();
  String _placeQuery = '';
  String _buildingQuery = '';
  String _anchorQuery = '';
  String _connectionQuery = '';
  String? _anchorStatusFilter;
  String? _buildingsPlaceFilterId;
  String? _anchorPointsBuildingFilterId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this)
      ..addListener(() {
        setState(() {});
        if (_tabController.index == 4 && !_usersLoaded) _loadUsers();
      });
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
        if (_buildingsPlaceFilterId != null &&
            !_places.any((p) => p['id'] == _buildingsPlaceFilterId)) {
          _buildingsPlaceFilterId = null;
        }
        if (_anchorPointsBuildingFilterId != null &&
            !_buildings.any((b) => b['id'] == _anchorPointsBuildingFilterId)) {
          _anchorPointsBuildingFilterId = null;
        }
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(
          context,
        )!.commonErrorLoadDataFailed(e.toString());
        _loading = false;
      });
    }
  }

  Future<void> _loadUsers() async {
    try {
      final result = await _userApi.get('/profiles');
      if (!mounted) return;
      setState(() {
        _users = (result as List? ?? []).cast<Map<String, dynamic>>();
        _usersLoaded = true;
        _usersError = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _usersError = AppLocalizations.of(
          context,
        )!.adminUsersErrorLoadFailed(e.toString());
        _usersLoaded = true;
      });
    }
  }

  Future<void> _setUserRole(Map<String, dynamic> user, int roleId) async {
    try {
      await _userApi.patch('/profiles/${user['id']}', {'role_id': roleId});
      await _loadUsers();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(
              context,
            )!.adminUsersErrorUpdateFailed(e.toString()),
          ),
        ),
      );
    }
  }

  Future<void> _promoteOrDemote(Map<String, dynamic> user) async {
    const adminRoleId = 2;
    const userRoleId = 1;
    final isAdmin = user['role_id'] == adminRoleId;
    if (!isAdmin) {
      await _setUserRole(user, adminRoleId);
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      title: l10n.adminUsersDemoteConfirmTitle,
      content: l10n.adminUsersDemoteConfirmContent(
        user['full_name'] as String? ?? user['id'] as String,
      ),
    );
    if (!confirmed) return;
    await _setUserRole(user, userRoleId);
  }

  Widget _usersTab() {
    final l10n = AppLocalizations.of(context)!;
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (!_usersLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_usersError != null) {
      return Center(child: Text(_usersError!));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: Text(
            l10n.adminUsersBootstrapNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: _users.isEmpty
              ? Center(child: Text(l10n.adminUsersEmpty))
              : ListView.builder(
                  itemCount: _users.length,
                  itemBuilder: (context, index) {
                    final user = _users[index];
                    final isAdmin = user['role_id'] == 2;
                    final isSelf = user['id'] == currentUserId;
                    return ListTile(
                      leading: Icon(
                        isAdmin
                            ? Icons.admin_panel_settings
                            : Icons.person_outline,
                        color: isAdmin ? Colors.indigo : Colors.grey,
                      ),
                      title: Text(
                        user['full_name'] as String? ?? user['id'] as String,
                      ),
                      subtitle: Text(
                        isAdmin
                            ? l10n.adminUsersRoleAdmin
                            : l10n.adminUsersRoleUser,
                      ),
                      trailing: IconButton(
                        icon: Icon(
                          isAdmin
                              ? Icons.remove_moderator_outlined
                              : Icons.admin_panel_settings_outlined,
                        ),
                        tooltip: isAdmin
                            ? l10n.adminUsersDemote
                            : l10n.adminUsersPromote,
                        onPressed: isSelf ? null : () => _promoteOrDemote(user),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
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
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonDelete),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(
                context,
              )!.commonErrorDeleteFailed(e.toString()),
            ),
          ),
        );
      }
    }
  }

  /// Qdrant cleanup that never blocks or surfaces as the "delete failed"
  /// error - the Postgres delete succeeding is what the confirmation dialog
  /// and reload actually depend on; leaving a few stale vectors behind on a
  /// bad day is far better than refusing to delete.
  Future<void> _bestEffort(Future<void> Function() action) async {
    try {
      await action();
    } on ApiException {
      // Swallowed - see doc comment above.
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

    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      title: l10n.adminDeletePlaceTitle,
      content: l10n.adminDeletePlaceContent(
        place['name'] as String? ?? place['id'] as String,
        buildings.length,
        anchors.length,
        photoCount,
        connectionCount,
      ),
    );
    if (!confirmed) return;
    await _bestEffort(
      () => Future.wait(
        buildings.map(
          (b) => _aiTrainingApi.delete('/index_building/${b['id']}'),
        ),
      ),
    );
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

    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      title: l10n.adminDeleteBuildingTitle,
      content: l10n.adminDeleteBuildingContent(
        building['name'] as String? ?? building['id'] as String,
        anchors.length,
        photoCount,
        connectionCount,
      ),
    );
    if (!confirmed) return;
    await _bestEffort(
      () => _aiTrainingApi.delete('/index_building/${building['id']}'),
    );
    await _runDelete(() => _mapApi.delete('/buildings/${building['id']}'));
  }

  Future<void> _deleteAnchorPoint(Map<String, dynamic> point) async {
    final photoCount = _photosOf(point['id'] as String).length;
    final connectionCount = _connectionsOf(point['id'] as String).length;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      title: l10n.adminDeleteAnchorTitle,
      content: l10n.adminDeleteAnchorContent(photoCount, connectionCount),
    );
    if (!confirmed) return;
    await _bestEffort(
      () => _aiTrainingApi.delete('/index_anchor/${point['id']}'),
    );
    await _runDelete(() => _mapApi.delete('/anchor-points/${point['id']}'));
  }

  Future<void> _deleteConnection(Map<String, dynamic> connection) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      title: l10n.adminDeleteConnectionTitle,
      content: l10n.commonCannotBeUndone,
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
    final l10n = AppLocalizations.of(context)!;
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
        _searchField(_placeSearchController, l10n.adminSearchPlacesHint),
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Text(l10n.adminPlacesEmpty))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final place = filtered[index];
                    final buildingCount = _buildingsOf(
                      place['id'] as String,
                    ).length;
                    return ListTile(
                      onTap: () {
                        setState(
                          () => _buildingsPlaceFilterId = place['id'] as String,
                        );
                        _tabController.animateTo(1);
                      },
                      leading: const Icon(Icons.flag, color: Colors.purple),
                      title: Text(
                        place['name'] as String? ?? place['id'] as String,
                      ),
                      subtitle: Text(
                        l10n.adminBuildingCountLabel(buildingCount) +
                            ((place['is_active'] as bool? ?? true)
                                ? ''
                                : l10n.adminInactiveSuffix),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: l10n.commonEdit,
                            onPressed: () => _editPlace(place),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: l10n.commonDelete,
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
    final l10n = AppLocalizations.of(context)!;
    final placesById = {for (final p in _places) p['id'] as String: p};
    final scopedPlace = _buildingsPlaceFilterId != null
        ? placesById[_buildingsPlaceFilterId]
        : null;
    final filtered =
        _buildings
            .where(
              (b) =>
                  (_buildingsPlaceFilterId == null ||
                      b['place_id'] == _buildingsPlaceFilterId) &&
                  (b['name'] as String? ?? '').toLowerCase().contains(
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
        if (scopedPlace != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InputChip(
                label: Text(
                  l10n.adminBuildingsInPlaceChip(
                    scopedPlace['name'] as String? ?? scopedPlace['id'],
                  ),
                ),
                onDeleted: () => setState(() => _buildingsPlaceFilterId = null),
              ),
            ),
          ),
        _searchField(_buildingSearchController, l10n.adminSearchBuildingsHint),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    scopedPlace != null
                        ? l10n.adminBuildingsEmptyIn(
                            scopedPlace['name'] as String? ?? scopedPlace['id'],
                          )
                        : l10n.adminBuildingsEmpty,
                  ),
                )
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final building = filtered[index];
                    final place = placesById[building['place_id']];
                    final anchorCount = _anchorPointsOf(
                      building['id'] as String,
                    ).length;
                    return ListTile(
                      onTap: () {
                        setState(
                          () => _anchorPointsBuildingFilterId =
                              building['id'] as String,
                        );
                        _tabController.animateTo(2);
                      },
                      leading: const Icon(
                        Icons.apartment,
                        color: Colors.orange,
                      ),
                      title: Text(
                        building['name'] as String? ?? building['id'] as String,
                      ),
                      subtitle: Text(
                        '${place?['name'] as String? ?? l10n.commonUnknownUniversity} · '
                        '${l10n.adminAnchorCountLabel(anchorCount)}'
                        '${(building['is_active'] as bool? ?? true) ? '' : l10n.adminInactiveSuffix}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: l10n.commonEdit,
                            onPressed: () => _editBuilding(building),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: l10n.commonDelete,
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

  Widget _statusFilterChips() {
    final l10n = AppLocalizations.of(context)!;
    const statuses = ['pending', 'verified', 'rejected'];
    final counts = {
      for (final s in statuses)
        s: _anchorPoints.where((p) => p['status'] == s).length,
    };

    Widget chip(String? value, String label) {
      final count = value == null ? _anchorPoints.length : counts[value] ?? 0;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(l10n.adminStatusChipLabel(label, count)),
          selected: _anchorStatusFilter == value,
          onSelected: (_) => setState(() => _anchorStatusFilter = value),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            chip(null, l10n.commonStatusAll),
            chip('pending', l10n.commonStatusPending),
            chip('verified', l10n.commonStatusVerified),
            chip('rejected', l10n.commonStatusRejected),
          ],
        ),
      ),
    );
  }

  Widget _anchorPointsTab() {
    final l10n = AppLocalizations.of(context)!;
    final buildingsById = {for (final b in _buildings) b['id'] as String: b};
    final scopedBuilding = _anchorPointsBuildingFilterId != null
        ? buildingsById[_anchorPointsBuildingFilterId]
        : null;
    final filtered =
        _anchorPoints
            .where(
              (p) =>
                  (_anchorPointsBuildingFilterId == null ||
                      p['building_id'] == _anchorPointsBuildingFilterId) &&
                  (_anchorStatusFilter == null ||
                      p['status'] == _anchorStatusFilter) &&
                  (p['location_description'] as String? ?? '')
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
        if (scopedBuilding != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InputChip(
                label: Text(
                  l10n.adminAnchorsInBuildingChip(
                    scopedBuilding['name'] as String? ?? scopedBuilding['id'],
                  ),
                ),
                onDeleted: () =>
                    setState(() => _anchorPointsBuildingFilterId = null),
              ),
            ),
          ),
        _statusFilterChips(),
        _searchField(_anchorSearchController, l10n.adminSearchAnchorPointsHint),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    scopedBuilding != null
                        ? l10n.adminAnchorsEmptyIn(
                            scopedBuilding['name'] as String? ??
                                scopedBuilding['id'],
                          )
                        : l10n.adminAnchorsEmpty,
                  ),
                )
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
                        '${building?['name'] as String? ?? l10n.commonUnknownBuilding} · '
                        '${l10n.adminStatusLabel(anchorStatusLabel(l10n, point['status'] as String? ?? 'unknown'))} · '
                        '${l10n.adminPhotoCountLabel(photos.length)}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.add_a_photo_outlined),
                            tooltip: l10n.adminAddPhotoTooltip,
                            onPressed: () => _addPhoto(point),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: l10n.commonEdit,
                            onPressed: () => _editAnchorPoint(point),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: l10n.commonDelete,
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
    final l10n = AppLocalizations.of(context)!;
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
        _searchField(
          _connectionSearchController,
          l10n.adminSearchConnectionsHint,
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Text(l10n.adminConnectionsEmpty))
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
                        '${aBuilding?['name'] as String? ?? l10n.commonUnknownBuilding} / '
                        '${bBuilding?['name'] as String? ?? l10n.commonUnknownBuilding}'
                        '${distance != null ? ' · ${distance}m' : ''}',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: l10n.commonDelete,
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
    final l10n = AppLocalizations.of(context)!;
    switch (_tabController.index) {
      case 0:
        return FloatingActionButton(
          tooltip: l10n.adminFabAddUniversity,
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
          tooltip: l10n.adminFabAddBuilding,
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
          tooltip: l10n.adminFabNewAnchorPoint,
          onPressed: () async {
            await Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const CaptureScreen()));
            _loadData();
          },
          child: const Icon(Icons.add_a_photo),
        );
      case 3:
        return FloatingActionButton(
          tooltip: l10n.adminFabConnectOnMap,
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
      default:
        // Users tab (index 4) - no "add" action, accounts are created via
        // signup, not an admin-initiated flow.
        return null;
    }
  }

  List<String> get _sectionTitles {
    final l10n = AppLocalizations.of(context)!;
    return [
      l10n.adminSectionUniversities,
      l10n.adminSectionBuildings,
      l10n.adminSectionAnchorPoints,
      l10n.adminSectionConnections,
      l10n.adminUsersTabLabel,
    ];
  }

  Widget _drawer() {
    final l10n = AppLocalizations.of(context)!;
    Widget item(int index, IconData icon, Color color, String label) {
      return ListTile(
        leading: Icon(icon, color: color),
        title: Text(label),
        selected: _tabController.index == index,
        onTap: () {
          _tabController.animateTo(index);
          Navigator.of(context).pop();
        },
      );
    }

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.adminUsersRoleAdmin,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                Text(
                  Supabase.instance.client.auth.currentUser?.email ?? '',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          item(0, Icons.flag, Colors.purple, l10n.adminSectionUniversities),
          item(1, Icons.apartment, Colors.orange, l10n.adminSectionBuildings),
          item(
            2,
            Icons.location_pin,
            Colors.green,
            l10n.adminSectionAnchorPoints,
          ),
          item(3, Icons.timeline, Colors.teal, l10n.adminSectionConnections),
          item(4, Icons.people, Colors.indigo, l10n.adminUsersTabLabel),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.my_location, color: Colors.teal),
            title: Text(AppLocalizations.of(context)!.adminSessions),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SessionsScreen()));
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      drawer: _drawer(),
      appBar: AppBar(
        title: Text(_sectionTitles[_tabController.index]),
        actions: [
          if (_tabController.index == 3)
            IconButton(
              icon: const Icon(Icons.list_alt),
              tooltip: l10n.adminAddConnectionFormTooltip,
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
            tooltip: l10n.commonRefresh,
            onPressed: _loading ? null : _loadData,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: AppLocalizations.of(context)!.homeSettingsTooltip,
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
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
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _placesTab(),
                  _buildingsTab(),
                  _anchorPointsTab(),
                  _connectionsTab(),
                  _usersTab(),
                ],
              ),
            ),
    );
  }
}

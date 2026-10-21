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
import 'feedback_screen.dart';
import 'sessions_screen.dart';
import '../user/settings_screen.dart';
import '../user/user_home_screen.dart';
import '../services/anchor_indexing.dart';
import '../services/api_error_messages.dart';
import '../services/exit_guard.dart';
import '../widgets/scrollable_message.dart';

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
  List<Map<String, dynamic>> _orphanedUsers = [];
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

  /// Tabs visited before the current one, so system back walks back
  /// through them instead of closing the app.
  final List<int> _tabHistory = [];
  int _lastTabIndex = 0;
  bool _navigatingBack = false;
  final _exitGuard = ExitGuard();
  bool _reindexing = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this)
      ..addListener(() {
        final index = _tabController.index;
        if (index != _lastTabIndex) {
          if (!_navigatingBack) _tabHistory.add(_lastTabIndex);
          _lastTabIndex = index;
          _navigatingBack = false;
        }
        setState(() {});
        if (index == 4 && !_usersLoaded) _loadUsers();
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
        )!.commonErrorLoadDataFailed(friendlyApiErrorMessage(context, e));
        _loading = false;
      });
    }
  }

  Future<void> _loadUsers() async {
    try {
      final results = await Future.wait([
        _userApi.get('/profiles'),
        // Best-effort: a failure here shouldn't hide the real users list.
        _userApi.get('/profiles/orphaned').catchError((_) => const []),
      ]);
      if (!mounted) return;
      setState(() {
        _users = (results[0] as List? ?? []).cast<Map<String, dynamic>>();
        _orphanedUsers = (results[1] as List? ?? [])
            .cast<Map<String, dynamic>>();
        _usersLoaded = true;
        _usersError = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _usersError = AppLocalizations.of(
          context,
        )!.adminUsersErrorLoadFailed(friendlyApiErrorMessage(context, e));
        _usersLoaded = true;
      });
    }
  }

  /// Pull-to-refresh: reloads the map data, plus the users list once it
  /// has been opened.
  Future<void> _refresh() async {
    await Future.wait([_loadData(), if (_usersLoaded) _loadUsers()]);
  }

  /// System back: leave the current tab (dropping the filter a drill-down
  /// set on it) for the previous one, then clear a remaining filter, then
  /// go to the first tab, and only then ask to press again to exit.
  void _handleBack() {
    final index = _tabController.index;
    void clearFilterOf(int tab) {
      if (tab == 1) _buildingsPlaceFilterId = null;
      if (tab == 2) _anchorPointsBuildingFilterId = null;
    }

    if (_tabHistory.isNotEmpty) {
      setState(() => clearFilterOf(index));
      _navigatingBack = true;
      _tabController.animateTo(_tabHistory.removeLast());
    } else if ((index == 1 && _buildingsPlaceFilterId != null) ||
        (index == 2 && _anchorPointsBuildingFilterId != null)) {
      setState(() => clearFilterOf(index));
    } else if (index != 0) {
      _navigatingBack = true;
      _tabController.animateTo(0);
    } else {
      _exitGuard.onBack(context);
    }
  }

  /// Re-sends every verified point with photos to the search index. Points
  /// verified while indexing was failing were never searchable, and
  /// re-saving each one by hand is slow.
  Future<void> _reindexVerified() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final targets = _anchorPoints
        .where(
          (p) =>
              p['status'] == 'verified' &&
              _photosOf(p['id'] as String).isNotEmpty,
        )
        .toList();
    if (targets.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.adminReindexNothing)));
      return;
    }
    setState(() => _reindexing = true);
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.adminReindexRunning(targets.length))),
    );
    var ok = 0;
    Object? lastError;
    for (final point in targets) {
      try {
        await indexAnchorPoint(
          _aiTrainingApi,
          point,
          _photosOf(point['id'] as String),
        );
        ok++;
      } on ApiException catch (e) {
        lastError = e;
      }
    }
    if (!mounted) return;
    setState(() => _reindexing = false);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            lastError == null
                ? l10n.adminReindexDone(ok, targets.length)
                : l10n.adminReindexDoneWithErrors(
                    ok,
                    targets.length,
                    friendlyApiErrorMessage(context, lastError),
                  ),
          ),
        ),
      );
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
            )!.adminUsersErrorUpdateFailed(friendlyApiErrorMessage(context, e)),
          ),
        ),
      );
    }
  }

  Future<void> _repairProfile(Map<String, dynamic> orphan) async {
    final l10n = AppLocalizations.of(context)!;
    final label = orphan['email'] as String? ?? orphan['id'] as String;
    try {
      await _userApi.post('/profiles/${orphan['id']}/repair', {});
      await _loadUsers();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.adminOrphanedRepairedSnackbar(label))),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.adminOrphanedErrorRepairFailed(
              friendlyApiErrorMessage(context, e),
            ),
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
      return ScrollableMessage(_usersError!);
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
        if (_orphanedUsers.isNotEmpty)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: Theme.of(context).colorScheme.errorContainer,
            child: ExpansionTile(
              initiallyExpanded: true,
              leading: Icon(
                Icons.warning_amber_rounded,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
              title: Text(
                l10n.adminOrphanedSectionTitle(_orphanedUsers.length),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
              subtitle: Text(
                l10n.adminOrphanedSectionHint,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
              children: [
                for (final orphan in _orphanedUsers)
                  ListTile(
                    title: Text(
                      orphan['email'] as String? ?? orphan['id'] as String,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.person_add_alt_1),
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      tooltip: l10n.adminOrphanedCreateProfileTooltip,
                      onPressed: () => _repairProfile(orphan),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: _users.isEmpty
              ? ScrollableMessage(l10n.adminUsersEmpty)
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
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
              )!.commonErrorDeleteFailed(friendlyApiErrorMessage(context, e)),
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
          anchorPointDescription: anchorDisplayName(
            AppLocalizations.of(context)!,
            point,
          ),
        ),
      ),
    );
    _loadData();
  }

  /// Opens the map connection builder already scoped to this point's
  /// university/building, zoomed in on it, and with it pre-selected as the
  /// first point of the pair.
  Future<void> _connectFromAnchorPoint(Map<String, dynamic> point) async {
    final buildingId = point['building_id'] as String?;
    final placeId =
        _buildings.firstWhere(
              (b) => b['id'] == buildingId,
              orElse: () => const {},
            )['place_id']
            as String?;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConnectAnchorPointsScreen(
          initialPlaceId: placeId,
          initialBuildingId: buildingId,
          initialAnchorPointId: point['id'] as String?,
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
              ? ScrollableMessage(l10n.adminPlacesEmpty)
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  // Clears the FAB, which otherwise covers the last row's
                  // trailing buttons.
                  padding: const EdgeInsets.only(bottom: 88),
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
              ? ScrollableMessage(
                  scopedPlace != null
                      ? l10n.adminBuildingsEmptyIn(
                          scopedPlace['name'] as String? ?? scopedPlace['id'],
                        )
                      : l10n.adminBuildingsEmpty,
                )
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  // Clears the FAB, which otherwise covers the last row's
                  // trailing buttons.
                  padding: const EdgeInsets.only(bottom: 88),
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

  /// [scopedAnchorPoints] is the building-filtered (but not yet
  /// status-filtered) list - counts here must reflect whichever building
  /// is currently selected, not every building's anchor points, or an
  /// admin drilled into one building sees a global "Verified (47)" count
  /// that doesn't match anything on screen.
  Widget _statusFilterChips(List<Map<String, dynamic>> scopedAnchorPoints) {
    final l10n = AppLocalizations.of(context)!;
    const statuses = ['pending', 'verified', 'rejected'];
    final counts = {
      for (final s in statuses)
        s: scopedAnchorPoints.where((p) => p['status'] == s).length,
    };

    Widget chip(String? value, String label) {
      final count = value == null
          ? scopedAnchorPoints.length
          : counts[value] ?? 0;
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
    final buildingScoped = _anchorPoints
        .where(
          (p) =>
              _anchorPointsBuildingFilterId == null ||
              p['building_id'] == _anchorPointsBuildingFilterId,
        )
        .toList();
    final filtered =
        buildingScoped
            .where(
              (p) =>
                  (_anchorStatusFilter == null ||
                      p['status'] == _anchorStatusFilter) &&
                  anchorDisplayName(
                    l10n,
                    p,
                  ).toLowerCase().contains(_anchorQuery),
            )
            .toList()
          ..sort(
            (a, b) => anchorDisplayName(
              l10n,
              a,
            ).compareTo(anchorDisplayName(l10n, b)),
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
        _statusFilterChips(buildingScoped),
        _searchField(_anchorSearchController, l10n.adminSearchAnchorPointsHint),
        Expanded(
          child: filtered.isEmpty
              ? ScrollableMessage(
                  scopedBuilding != null
                      ? l10n.adminAnchorsEmptyIn(
                          scopedBuilding['name'] as String? ??
                              scopedBuilding['id'],
                        )
                      : l10n.adminAnchorsEmpty,
                )
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  // Clears the FAB, which otherwise covers the last row's
                  // trailing buttons.
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final point = filtered[index];
                    final building = buildingsById[point['building_id']];
                    final photos = _photosOf(point['id'] as String);
                    final thumbUrl = photos.isNotEmpty
                        ? photos.first['image_url'] as String?
                        : null;
                    return ListTile(
                      onTap: () => _connectFromAnchorPoint(point),
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
                      title: Text(anchorDisplayName(l10n, point)),
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
      return point == null
          ? anchorPointId ?? '?'
          : anchorDisplayName(l10n, point);
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
              ? ScrollableMessage(l10n.adminConnectionsEmpty)
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  // Clears the FAB, which otherwise covers the last row's
                  // trailing buttons.
                  padding: const EdgeInsets.only(bottom: 88),
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
              MaterialPageRoute(
                builder: (_) =>
                    AddBuildingScreen(initialPlaceId: _buildingsPlaceFilterId),
              ),
            );
            _loadData();
          },
          child: const Icon(Icons.add),
        );
      case 2:
        return FloatingActionButton(
          tooltip: l10n.adminFabNewAnchorPoint,
          onPressed: () async {
            final buildingId = _anchorPointsBuildingFilterId;
            final placeId = buildingId == null
                ? null
                : _buildings.firstWhere(
                        (b) => b['id'] == buildingId,
                        orElse: () => const {},
                      )['place_id']
                      as String?;
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CaptureScreen(
                  initialPlaceId: placeId,
                  initialBuildingId: buildingId,
                ),
              ),
            );
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
            title: Text(l10n.adminSessions),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SessionsScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.comment_outlined, color: Colors.teal),
            title: Text(l10n.feedbackScreenTitle),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const FeedbackScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.manage_search, color: Colors.teal),
            title: Text(l10n.adminReindexMenu),
            enabled: !_reindexing && !_loading,
            onTap: () {
              Navigator.of(context).pop();
              _reindexVerified();
            },
          ),
          ListTile(
            leading: const Icon(Icons.visibility_outlined, color: Colors.teal),
            title: Text(l10n.adminTestAsUser),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const UserHomeScreen(adminPreview: true),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: _scaffold(l10n),
    );
  }

  Widget _scaffold(AppLocalizations l10n) {
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
            onPressed: _loading ? null : _refresh,
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
          ? RefreshIndicator(
              onRefresh: _refresh,
              child: ScrollableMessage(_error!),
            )
          : RefreshIndicator(
              onRefresh: _refresh,
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

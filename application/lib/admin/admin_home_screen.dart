import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/map_scope.dart';
import '../services/map_sync.dart';
import '../widgets/admin_map/admin_map.dart';
import '../widgets/map_conflict.dart';
import 'add_building_screen.dart';
import 'add_connection_screen.dart';
import 'add_place_screen.dart';
import 'capture_photo_screen.dart';
import 'capture_screen.dart';
import 'edit_anchor_point_screen.dart'
    show EditAnchorPointScreen, anchorStatusLabel;
import 'edit_building_screen.dart';
import 'edit_place_screen.dart';
import 'feedback_screen.dart';
import 'map_home.dart';
import 'sessions_screen.dart';
import '../user/settings_screen.dart';
import '../user/user_home_screen.dart';
import '../services/anchor_filters.dart';
import '../services/anchor_indexing.dart';
import '../services/api_error_messages.dart';
import '../widgets/admin_guide.dart';
import '../services/capture_checks.dart';
import '../services/connect_chain.dart';
import '../services/connection_filters.dart';
import '../services/exit_guard.dart';
import '../services/location_types.dart';
import '../services/floor_view.dart';
import '../widgets/guardrail_dialogs.dart';
import '../widgets/connection_warning_dialog.dart';
import '../widgets/drawer_list.dart';
import '../widgets/fab_row.dart';
import '../widgets/review_list.dart';
import '../widgets/scope_dropdowns.dart';
import '../widgets/scrollable_message.dart';
import '../theme/admin_palette.dart';

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
  AnchorFilters _anchorFilters = AnchorFilters.none;
  String? _buildingsPlaceFilterId;
  String? _anchorPointsBuildingFilterId;
  String? _anchorPointsPlaceFilterId;
  ConnectionFilters _connectionFilters = ConnectionFilters.none;

  /// The sections, in drawer order. The map is first and opens the app (C2).
  static const _kMap = 0;
  static const _kUniversities = 1;
  static const _kBuildings = 2;
  static const _kPoints = 3;
  static const _kConnections = 4;
  static const _kUsers = 5;

  /// Where the Map section is: everything, a university or a building.
  MapScope _mapScope = MapScope.all;

  /// Tabs visited before the current one, so system back walks back
  /// through them instead of closing the app.
  final List<int> _tabHistory = [];
  int _lastTabIndex = 0;
  bool _navigatingBack = false;
  final _exitGuard = ExitGuard();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();
  bool _reindexing = false;

  /// Verified photos missing from the photo index (null: unknown).
  int? _unsearchablePhotos;

  /// What changed since, for GET /changes (A5): set from the server's own
  /// clock after a full load. Null when the server can't answer it yet, and
  /// then every refresh is a full one.
  String? _since;
  Timer? _syncTimer;
  Future<void>? _syncing;
  bool _wasCovered = false;

  /// The point being moved on the map.
  Map<String, dynamic>? _movingPoint;

  /// Connect mode on the map (C3): the first point of the next connection,
  /// and the pairs (see [connectionPairKey]) still being saved.
  bool _connecting = false;
  String? _connectFromId;
  final Set<String> _pendingPairs = {};

  /// The last "show this on the map" request (MapHome acts on each new one).
  MapFocus? _mapFocus;

  /// Connections tab: the university and building it's narrowed to.
  String? _connectionsPlaceId;
  String? _connectionsBuildingId;
  LatLng? _moveTarget;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this)
      ..addListener(() {
        final index = _tabController.index;
        if (index != _lastTabIndex) {
          if (!_navigatingBack) _tabHistory.add(_lastTabIndex);
          _lastTabIndex = index;
          _navigatingBack = false;
          // A move belongs to the map it started on, and so does connecting.
          _movingPoint = null;
          _moveTarget = null;
          if (index != _kMap) {
            _connecting = false;
            _connectFromId = null;
            // Done with; a map built again later mustn't act on it again.
            _mapFocus = null;
          }
        }
        setState(() {});
        if (index == _kUsers && !_usersLoaded) _loadUsers();
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
    _loadAll();
    // Other admins' changes appear within about 30 s.
    _syncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _onSyncTick(),
    );
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _tabController.dispose();
    _placeSearchController.dispose();
    _buildingSearchController.dispose();
    _anchorSearchController.dispose();
    _connectionSearchController.dispose();
    super.dispose();
  }

  void _onSyncTick() {
    if (!mounted) return;
    final covered = !(ModalRoute.of(context)?.isCurrent ?? true);
    switch (syncTickAction(covered: covered, wasCovered: _wasCovered)) {
      case SyncTick.skip:
        _wasCovered = true;
      case SyncTick.silent:
        _wasCovered = false;
        _sync(announce: false);
      case SyncTick.announce:
        _sync(announce: true);
    }
  }

  /// After an edit, or anything that changed the map: only what changed since
  /// the last look, not all five lists (A5).
  Future<void> _loadData() => _sync(announce: false);

  /// Fetches and merges `/changes`, one at a time. With [announce] (the
  /// 30 s timer), says how many changes came from other admins: this admin's
  /// own edits were already merged right after saving, so they don't count.
  Future<void> _sync({required bool announce}) async {
    while (_syncing != null) {
      await _syncing;
    }
    final since = _since;
    if (since == null) {
      // The server can't answer /changes (yet): reload as before, but not
      // every 30 s.
      if (!announce) await _loadAll();
      return;
    }
    final done = Completer<void>();
    _syncing = done.future;
    try {
      final changes = await _mapApi.get(
        '/changes?since=${Uri.encodeQueryComponent(since)}',
      );
      if (!mounted || changes is! Map<String, dynamic>) return;
      if (changes['full'] == true) {
        await _loadAll();
        return;
      }
      final merged = applyChanges(
        MapLists(
          places: _places,
          buildings: _buildings,
          anchorPoints: _anchorPoints,
          photos: _photos,
          connections: _connections,
        ),
        changes,
      );
      setState(() {
        _places = merged.lists.places;
        _buildings = merged.lists.buildings;
        _anchorPoints = merged.lists.anchorPoints;
        _photos = merged.lists.photos;
        _connections = merged.lists.connections;
        _since = changes['next_since'] as String?;
        _dropStaleScopes();
      });
      if (announce && merged.newChanges > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(
                context,
              )!.mapUpdatedByOthers(merged.newChanges),
            ),
          ),
        );
      }
      if (!announce) _refreshIndexStatus();
    } on ApiException {
      // Something is off: fall back to what always worked.
      if (!announce && mounted) await _loadAll();
    } finally {
      _syncing = null;
      done.complete();
    }
  }

  /// The server's clock, to ask /changes from: a phone's clock can be off.
  /// Null when /changes isn't there, as before the migration.
  Future<String?> _serverSince() async {
    try {
      final since = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      final changes = await _mapApi.get(
        '/changes?since=${Uri.encodeQueryComponent(since.toIso8601String())}',
      );
      return changes is Map ? changes['next_since'] as String? : null;
    } on ApiException {
      return null;
    }
  }

  /// A filter scoped to a university or building that's gone is dropped.
  void _dropStaleScopes() {
    if (_buildingsPlaceFilterId != null &&
        !_places.any((p) => p['id'] == _buildingsPlaceFilterId)) {
      _buildingsPlaceFilterId = null;
    }
    if (_anchorPointsBuildingFilterId != null &&
        !_buildings.any((b) => b['id'] == _anchorPointsBuildingFilterId)) {
      _anchorPointsBuildingFilterId = null;
    }
    if (!_places.any((p) => p['id'] == _anchorPointsPlaceFilterId)) {
      _anchorPointsPlaceFilterId = null;
    }
    if (!_places.any((p) => p['id'] == _connectionsPlaceId)) {
      _connectionsPlaceId = null;
    }
    if (!_buildings.any((b) => b['id'] == _connectionsBuildingId)) {
      _connectionsBuildingId = null;
    }
    _mapScope = _mapScope.existingIn(
      placeIds: {for (final p in _places) p['id'] as String},
      buildingIds: {for (final b in _buildings) b['id'] as String},
    );
  }

  /// All five lists: on opening, on pull-to-refresh, and as a fallback.
  Future<void> _loadAll() async {
    // Asked before the lists, so nothing changed between them is missed.
    final since = _serverSince();
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
        _dropStaleScopes();
        _loading = false;
        _error = null;
      });
      _since = await since;
      _refreshIndexStatus();
    } catch (e) {
      // Not only ApiException: a malformed response must end the spinner too.
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
    await Future.wait([_loadAll(), if (_usersLoaded) _loadUsers()]);
  }

  /// System back: on the map, cancel a move, then go up a level. Elsewhere,
  /// leave the current tab (dropping the filter a drill-down set on it) for
  /// the previous one, then clear a remaining filter, then go to the map,
  /// and only then ask to press again to exit.
  void _handleBack() {
    final index = _tabController.index;
    if (index == _kMap && _movingPoint != null) {
      setState(() {
        _movingPoint = null;
        _moveTarget = null;
      });
      return;
    }
    if (index == _kMap && _connectFromId != null) {
      setState(() => _connectFromId = null);
      return;
    }
    if (index == _kMap && _connecting) {
      setState(() => _connecting = false);
      return;
    }
    if (index == _kMap && !_anchorFilters.isEmpty) {
      setState(() => _anchorFilters = AnchorFilters.none);
      return;
    }
    if (index == _kMap && !_mapScope.isAll) {
      setState(() => _mapScope = _mapScope.up);
      return;
    }
    // Metadata filters on the Anchor points tab are cleared first.
    if (index == _kPoints && !_anchorFilters.isEmpty) {
      setState(() => _anchorFilters = AnchorFilters.none);
      return;
    }
    void clearFilterOf(int tab) {
      if (tab == _kBuildings) _buildingsPlaceFilterId = null;
      if (tab == _kPoints) {
        _anchorPointsBuildingFilterId = null;
        _anchorPointsPlaceFilterId = null;
      }
    }

    if (_tabHistory.isNotEmpty) {
      setState(() => clearFilterOf(index));
      _navigatingBack = true;
      _tabController.animateTo(_tabHistory.removeLast());
    } else if ((index == _kBuildings && _buildingsPlaceFilterId != null) ||
        (index == _kPoints &&
            (_anchorPointsBuildingFilterId != null ||
                _anchorPointsPlaceFilterId != null))) {
      setState(() => clearFilterOf(index));
    } else if (index != _kMap) {
      _navigatingBack = true;
      _tabController.animateTo(_kMap);
    } else {
      _exitGuard.onBack(context);
    }
  }

  /// Re-sends every verified point with photos to the search index. Points
  /// verified while indexing was failing were never searchable, and
  /// re-saving each one by hand is slow.
  /// Sends to `/index_anchor` the verified points with a photo that isn't
  /// searchable yet (`/index_status`; all of them if that can't be read),
  /// retrying each failure twice, then lists the points that still failed.
  Future<void> _reindexVerified() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    // First drop index entries that shouldn't be there (deleted photos,
    // unverified points); best effort, older servers lack it.
    try {
      await _aiTrainingApi.post('/reconcile', {});
    } on ApiException {
      // Re-indexing below still helps.
    }
    final indexed = await fetchIndexedPhotoIds(_aiTrainingApi);
    if (!mounted) return;
    final targets = pointsMissingFromIndex(_anchorPoints, _photosOf, indexed);
    if (targets.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            indexed == null
                ? l10n.adminReindexNothing
                : l10n.adminReindexAllSearchable,
          ),
        ),
      );
      setState(() => _unsearchablePhotos = 0);
      return;
    }
    setState(() => _reindexing = true);
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.adminReindexRunning(targets.length))),
    );
    var ok = 0;
    Object? lastError;
    final failed = <Map<String, dynamic>>[];
    for (final point in targets) {
      var done = false;
      for (var attempt = 0; attempt < 3 && !done; attempt++) {
        try {
          await indexAnchorPoint(
            _aiTrainingApi,
            point,
            _photosOf(point['id'] as String),
          );
          done = true;
        } on ApiException catch (e) {
          lastError = e;
        }
      }
      if (done) {
        ok++;
      } else {
        failed.add(point);
      }
    }
    if (!mounted) return;
    setState(() => _reindexing = false);
    messenger.hideCurrentSnackBar();
    _refreshIndexStatus();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.adminReindexResultTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.adminReindexDone(ok, targets.length)),
              if (failed.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.adminReindexFailedList(
                    friendlyApiErrorMessage(context, lastError!),
                  ),
                ),
                for (final point in failed)
                  Text('• ${_pointLabel(l10n, point)}'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
  }

  /// How many verified photos aren't searchable, for the drawer warning.
  /// Best effort: unknown leaves the warning off.
  Future<void> _refreshIndexStatus() async {
    final indexed = await fetchIndexedPhotoIds(_aiTrainingApi);
    if (!mounted || indexed == null) return;
    setState(
      () => _unsearchablePhotos = unsearchablePhotoCount(
        _anchorPoints,
        _photosOf,
        indexed,
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

  /// Deactivated accounts are refused by every service (packages'
  /// get_caller_id answers 403) until an admin activates them again.
  Future<void> _setUserActive(Map<String, dynamic> user, bool active) async {
    final l10n = AppLocalizations.of(context)!;
    if (!active) {
      final confirmed = await _confirm(
        title: l10n.adminUserDeactivateTooltip,
        content: l10n.adminUserDeactivateConfirm(
          user['full_name'] as String? ?? user['id'] as String,
        ),
      );
      if (!confirmed) return;
    }
    try {
      await _userApi.patch('/profiles/${user['id']}', {'is_active': active});
      await _loadUsers();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.adminUsersErrorUpdateFailed(
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
                    final active = user['is_active'] as bool? ?? true;
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
                        [
                          isAdmin
                              ? l10n.adminUsersRoleAdmin
                              : l10n.adminUsersRoleUser,
                          if (!active) l10n.adminUserInactive,
                        ].join(' · '),
                        style: active
                            ? null
                            : const TextStyle(color: Colors.red),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(
                              isAdmin
                                  ? Icons.remove_moderator_outlined
                                  : Icons.admin_panel_settings_outlined,
                            ),
                            tooltip: isAdmin
                                ? l10n.adminUsersDemote
                                : l10n.adminUsersPromote,
                            onPressed: isSelf
                                ? null
                                : () => _promoteOrDemote(user),
                          ),
                          IconButton(
                            icon: Icon(
                              active
                                  ? Icons.person_off_outlined
                                  : Icons.person_add_alt_outlined,
                            ),
                            tooltip: active
                                ? l10n.adminUserDeactivateTooltip
                                : l10n.adminUserActivateTooltip,
                            // Not on your own row: no locking yourself out.
                            onPressed: isSelf
                                ? null
                                : () => _setUserActive(user, !active),
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

  /// Deletes in the database first; [afterSuccess] (removing the points
  /// from photo search) runs only once that worked. The other way round, a
  /// delete that failed left points listed but no longer recognisable.
  Future<void> _runDelete(
    Future<void> Function() action, {
    Future<void> Function()? afterSuccess,
  }) async {
    try {
      await action();
      if (afterSuccess != null) await _bestEffort(afterSuccess);
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
      content:
          l10n.adminDeletePlaceContent(
            place['name'] as String? ?? place['id'] as String,
            buildings.length,
            anchors.length,
            photoCount,
            connectionCount,
          ) +
          l10n.adminDeleteKeepsHistoryNote,
    );
    if (!confirmed) return;
    await _runDelete(
      () => _mapApi.delete('/places/${place['id']}'),
      afterSuccess: () => Future.wait(
        buildings.map(
          (b) => _aiTrainingApi.delete('/index_building/${b['id']}'),
        ),
      ),
    );
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
      content:
          l10n.adminDeleteBuildingContent(
            building['name'] as String? ?? building['id'] as String,
            anchors.length,
            photoCount,
            connectionCount,
          ) +
          l10n.adminDeleteKeepsHistoryNote,
    );
    if (!confirmed) return;
    await _runDelete(
      () => _mapApi.delete('/buildings/${building['id']}'),
      afterSuccess: () =>
          _aiTrainingApi.delete('/index_building/${building['id']}'),
    );
  }

  Future<void> _deleteAnchorPoint(Map<String, dynamic> point) async {
    final photoCount = _photosOf(point['id'] as String).length;
    final connectionCount = _connectionsOf(point['id'] as String).length;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      title: l10n.adminDeleteAnchorTitle,
      content:
          l10n.adminDeleteAnchorContent(photoCount, connectionCount) +
          l10n.adminDeleteKeepsHistoryNote,
    );
    if (!confirmed) return;
    await _runDelete(
      () => _mapApi.delete('/anchor-points/${point['id']}'),
      afterSuccess: () => _aiTrainingApi.delete('/index_anchor/${point['id']}'),
    );
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

  /// The connection's warning for users ("three steps down"), spoken as
  /// they start walking it. Testers asked to be told about obstacles.
  Future<void> _editConnectionWarning(Map<String, dynamic> connection) async {
    final l10n = AppLocalizations.of(context)!;
    final notes = await showConnectionWarningDialog(
      context,
      connection['notes'] as String? ?? '',
    );
    if (notes == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _mapApi.patch('/anchor-point-connections/${connection['id']}', {
        'notes': notes,
      });
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.connectionWarningSaved)),
      );
      await _loadData();
    } on ApiException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.connectionWarningSaveFailed(
              friendlyApiErrorMessage(context, e),
            ),
          ),
        ),
      );
    }
  }

  Future<void> _editPlace(Map<String, dynamic> place) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EditPlaceScreen(place: place)),
    );
    if (changed == true) await _loadData();
  }

  Future<void> _editBuilding(Map<String, dynamic> building) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EditBuildingScreen(building: building)),
    );
    if (changed == true) _loadData();
  }

  Future<void> _editAnchorPoint(Map<String, dynamic> point) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditAnchorPointScreen(anchorPoint: point),
      ),
    );
    // Always reload: photos added or deleted from the edit screen count
    // even when the admin backs out without saving.
    await _loadData();
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
  /// Connect mode on the map, with [point] as the first of the pair: the
  /// next point tapped connects to it (a point row's tap, the sheet's
  /// Connect).
  void _connectFromAnchorPoint(Map<String, dynamic> point) {
    if (_tabController.index != _kMap) _tabController.animateTo(_kMap);
    setState(() {
      _movingPoint = null;
      _moveTarget = null;
      _connecting = true;
      _connectFromId = point['id'] as String?;
      _mapFocus = MapFocus(PointHit(point), open: false);
    });
  }

  /// Shows [item] on the map: a notice's point or connection, a row's
  /// "Show on map".
  void _showOnMap(AdminMapHit item) {
    if (_tabController.index != _kMap) _tabController.animateTo(_kMap);
    setState(() => _mapFocus = MapFocus(item));
  }

  String _describePoint(String id) {
    final l10n = AppLocalizations.of(context)!;
    final point = _anchorPoints.firstWhere(
      (p) => p['id'] == id,
      orElse: () => {'id': id},
    );
    return anchorLabel(
      l10n,
      point,
      _buildingName(point['building_id'] as String?),
    );
  }

  void _snack(String text, {int seconds = 4}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: Duration(seconds: seconds),
          content: Text(text),
        ),
      );
  }

  /// A point tapped in connect mode (see [connectTap]). Connecting is
  /// optimistic: the line shows (dotted grey) and the selection moves on at
  /// once, so the next tap works while this one saves; only the same pair
  /// waits.
  Future<void> _onConnectTap(Map<String, dynamic> point) async {
    final l10n = AppLocalizations.of(context)!;
    HapticFeedback.selectionClick();
    final step = connectTap(
      selectedId: _connectFromId,
      tapped: point,
      connections: _connections,
      pointsById: {for (final p in _anchorPoints) p['id'] as String: p},
    );
    switch (step) {
      case ConnectSelect(:final id):
        setState(() => _connectFromId = id);
      case ConnectDeselect():
        setState(() => _connectFromId = null);
      case ConnectMoveOn(:final id):
        setState(() => _connectFromId = id);
        _snack(l10n.connectErrorAlreadyConnected, seconds: 2);
      case ConnectRefused(
        :final fromId,
        :final toId,
        :final problem,
        :final distance,
      ):
        HapticFeedback.heavyImpact();
        _snack(
          problem == ConnectionProblem.tooLong
              ? l10n.connectErrorTooFar(
                  _describePoint(fromId),
                  _describePoint(toId),
                  distance!.toStringAsFixed(0),
                )
              : l10n.connectErrorFloorChange(
                  _describePoint(fromId),
                  _describePoint(toId),
                ),
          seconds: 6,
        );
      case ConnectPair():
        await _saveConnection(step);
    }
  }

  Future<void> _saveConnection(ConnectPair pair) async {
    final l10n = AppLocalizations.of(context)!;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      _snack(l10n.commonNotSignedIn);
      return;
    }
    final key = connectionPairKey(pair.fromId, pair.toId);
    if (_pendingPairs.contains(key)) return;
    final pending = <String, dynamic>{
      'id': 'pending-$key',
      'anchor_point_a_id': pair.fromId,
      'anchor_point_b_id': pair.toId,
      'pending': true,
    };
    setState(() {
      _pendingPairs.add(key);
      _connections = [..._connections, pending];
      _connectFromId = pair.toId;
    });
    try {
      final result = await _mapApi.post('/anchor-point-connections', {
        'anchor_point_a_id': pair.fromId,
        'anchor_point_b_id': pair.toId,
        'created_by': userId,
      });
      if (!mounted) return;
      final created = result is List && result.isNotEmpty
          ? (result.first as Map).cast<String, dynamic>()
          : null;
      setState(() {
        _connections = [
          for (final c in _connections)
            // The sync may have brought the saved row already.
            if (!identical(c, pending) &&
                (created == null || c['id'] != created['id']))
              c,
          created ?? {...pending, 'pending': false},
        ];
      });
      final distance = pair.distance;
      pair.long ? HapticFeedback.mediumImpact() : HapticFeedback.lightImpact();
      _snack(
        pair.long
            ? l10n.connectSnackbarConnectedLong(distance!.toStringAsFixed(0))
            : l10n.connectSnackbarConnected(
                _describePoint(pair.fromId),
                _describePoint(pair.toId),
              ),
        seconds: pair.long ? 4 : 2,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _connections = [
          for (final c in _connections)
            if (!identical(c, pending)) c,
        ];
      });
      _snack(
        // Only a real duplicate; a 500 used to read as "already connected"
        // too, hiding outages.
        e.statusCode == 409
            ? l10n.connectErrorAlreadyConnected
            : l10n.connectErrorConnectFailed(
                friendlyApiErrorMessage(context, e),
              ),
      );
    } finally {
      if (mounted) setState(() => _pendingPairs.remove(key));
    }
  }

  /// A connection's data and actions on the map.
  Widget _connectionDetails(Map<String, dynamic> c, VoidCallback close) {
    final l10n = AppLocalizations.of(context)!;
    final aId = c['anchor_point_a_id'] as String? ?? '';
    final bId = c['anchor_point_b_id'] as String? ?? '';
    Map<String, dynamic>? point(String id) {
      for (final p in _anchorPoints) {
        if (p['id'] == id) return p;
      }
      return null;
    }

    final a = point(aId);
    final b = point(bId);
    final meters = (c['distance_meters'] as num?)?.toStringAsFixed(1);
    final notes = (c['notes'] as String? ?? '').trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.timeline, color: kAdminPalette.connectionActive),
          title: Text('${_describePoint(aId)} ↔ ${_describePoint(bId)}'),
          subtitle: Text(
            [
              if (meters != null)
                c['distance_manual'] == true
                    ? l10n.adminConnectionDistanceTyped(meters)
                    : l10n.adminConnectionDistance(meters),
              if (a != null && b != null && pointFloor(a) != pointFloor(b))
                l10n.adminConnectionChangesFloor,
              notes.isEmpty
                  ? l10n.adminConnectionNoWarning
                  : l10n.adminConnectionWarning(notes),
            ].join('\n'),
          ),
        ),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.warning_amber_outlined),
              label: Text(l10n.adminConnectionEditWarning),
              onPressed: () {
                close();
                _editConnectionWarning(c);
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.commonDelete),
              onPressed: () {
                close();
                _deleteConnection(c);
              },
            ),
          ],
        ),
      ],
    );
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
                  padding: EdgeInsets.only(bottom: _fabClearance),
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
                        _tabController.animateTo(_kBuildings);
                      },
                      leading: Icon(
                        Icons.flag,
                        color: kAdminPalette.university,
                      ),
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
        ScopeDropdowns(
          places: _places,
          buildings: _buildings,
          placeId: _buildingsPlaceFilterId,
          buildingId: null,
          showBuilding: false,
          onChanged: (placeId, _) =>
              setState(() => _buildingsPlaceFilterId = placeId),
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
                  padding: EdgeInsets.only(bottom: _fabClearance),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final building = filtered[index];
                    final place = placesById[building['place_id']];
                    final anchorCount = _anchorPointsOf(
                      building['id'] as String,
                    ).length;
                    return ListTile(
                      onTap: () {
                        setState(() {
                          _anchorPointsBuildingFilterId =
                              building['id'] as String;
                          _anchorPointsPlaceFilterId =
                              building['place_id'] as String?;
                        });
                        _tabController.animateTo(_kPoints);
                      },
                      leading: Icon(
                        Icons.apartment,
                        color: kAdminPalette.building,
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
  /// Verify or unverify straight from the list or the map. Verifying needs
  /// at least one photo (the backend enforces it too) and adds the point to
  /// photo search; unverifying puts it back to pending and removes it.
  Future<void> _setAnchorStatus(
    Map<String, dynamic> point,
    String status,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final id = point['id'] as String;
    final name = _pointLabel(l10n, point);
    final photos = _photosOf(id);
    void show(String text) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));

    if (status == 'verified' && photos.isEmpty) {
      show(l10n.editAnchorErrorVerifyNeedsPhoto);
      return;
    }
    if (status == 'verified' &&
        _connectionsOf(id).isEmpty &&
        !await confirmVerifyUnconnected(context, name: name)) {
      return;
    }
    if (!mounted) return;
    try {
      // A second admin verifying the same point finds out here, instead of
      // both seeming to succeed.
      final saved = await saveAnchorPoint(
        context,
        _mapApi,
        id: point['id'] as String,
        original: point,
        changes: {'status': status},
        name: name,
      );
      if (!saved) {
        show(l10n.mapConflictKeptTheirs(name));
        await _loadData();
        return;
      }
    } on ApiException catch (e) {
      if (mounted) {
        show(
          l10n.editAnchorErrorUpdateFailed(friendlyApiErrorMessage(context, e)),
        );
      }
      return;
    }
    try {
      if (status == 'verified') {
        await indexAnchorPoint(_aiTrainingApi, point, photos);
      } else {
        await _aiTrainingApi.delete('/index_anchor/$id');
      }
      show(
        status == 'verified'
            ? l10n.adminAnchorVerifiedSnackbar(name)
            : l10n.adminAnchorUnverifiedSnackbar(name),
      );
    } on ApiException catch (e) {
      if (mounted) {
        final reason = friendlyApiErrorMessage(context, e);
        show(
          status == 'verified'
              ? l10n.editAnchorErrorIndexingFailed(reason)
              : l10n.editAnchorErrorUnindexFailed(reason),
        );
      }
    }
    await _loadData();
  }

  Widget _statusToggleButton(Map<String, dynamic> point) {
    final l10n = AppLocalizations.of(context)!;
    final verified = point['status'] == 'verified';
    return IconButton(
      icon: Icon(
        verified ? Icons.remove_done : Icons.verified_outlined,
        color: verified ? null : kAdminPalette.verified,
      ),
      tooltip: verified
          ? l10n.adminAnchorUnverifyTooltip
          : l10n.adminAnchorVerifyTooltip,
      onPressed: () =>
          _setAnchorStatus(point, verified ? 'pending' : 'verified'),
    );
  }

  /// Details and actions for a point tapped on the Anchor points map.
  /// A point's data and actions: the map's sheet, or the map's side panel.
  /// [close] hides it before an action runs.
  Widget _pointDetails(Map<String, dynamic> point, VoidCallback close) {
    final l10n = AppLocalizations.of(context)!;
    final photos = _photosOf(point['id'] as String);
    final building = _buildings.firstWhere(
      (b) => b['id'] == point['building_id'],
      orElse: () => const {},
    );
    final type = kLocationTypes[point['location_type_id'] as int?];
    final thumbUrl = photos.isNotEmpty
        ? photos.first['image_url'] as String?
        : null;
    final verified = point['status'] == 'verified';

    Widget action(IconData icon, String label, VoidCallback onTap) {
      return TextButton.icon(
        icon: Icon(icon),
        label: Text(label),
        onPressed: () {
          close();
          onTap();
        },
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (thumbUrl != null)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    thumbUrl,
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    anchorDisplayName(l10n, point),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    [
                      if (type != null) locationTypeLabel(l10n, type),
                      building['name'] as String? ?? l10n.commonUnknownBuilding,
                      l10n.adminStatusLabel(
                        anchorStatusLabel(
                          l10n,
                          point['status'] as String? ?? 'unknown',
                        ),
                      ),
                      l10n.adminPhotoCountLabel(photos.length),
                    ].join(' · '),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 4,
          children: [
            action(
              Icons.edit_outlined,
              l10n.commonEdit,
              () => _editAnchorPoint(point),
            ),
            action(
              Icons.open_with,
              l10n.adminAnchorMoveAction,
              () => setState(() {
                _movingPoint = point;
                _moveTarget = null;
              }),
            ),
            action(
              verified ? Icons.remove_done : Icons.verified_outlined,
              verified
                  ? l10n.adminAnchorUnverifyTooltip
                  : l10n.adminAnchorVerifyTooltip,
              () => _setAnchorStatus(point, verified ? 'pending' : 'verified'),
            ),
            action(
              Icons.timeline,
              l10n.adminAnchorConnectAction,
              () => _connectFromAnchorPoint(point),
            ),
            action(
              Icons.add_a_photo_outlined,
              l10n.adminAddPhotoTooltip,
              () => _addPhoto(point),
            ),
          ],
        ),
      ],
    );
  }

  /// A university's data and actions on the map.
  Widget _placeDetails(Map<String, dynamic> place, VoidCallback close) {
    final l10n = AppLocalizations.of(context)!;
    final active = place['is_active'] as bool? ?? true;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.flag,
            color: active ? kAdminPalette.university : kAdminPalette.inactive,
          ),
          title: Text(place['name'] as String? ?? ''),
          subtitle: Text(
            [
              if (place['code'] case final String code) code,
              l10n.adminBuildingCountLabel(
                _buildingsOf(place['id'] as String).length,
              ),
              if (!active) l10n.adminMapInactive,
            ].join(' · '),
          ),
        ),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.edit_outlined),
              label: Text(l10n.commonEdit),
              onPressed: () {
                close();
                _editPlace(place);
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.list),
              label: Text(l10n.adminMapOpenBuildingsList),
              onPressed: () {
                close();
                setState(() => _buildingsPlaceFilterId = place['id'] as String);
                _tabController.animateTo(_kBuildings);
              },
            ),
          ],
        ),
      ],
    );
  }

  /// A building's data and actions on the map.
  Widget _buildingDetails(Map<String, dynamic> building, VoidCallback close) {
    final l10n = AppLocalizations.of(context)!;
    final active = building['is_active'] as bool? ?? true;
    final place = _places.firstWhere(
      (p) => p['id'] == building['place_id'],
      orElse: () => const {},
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.apartment,
            color: active ? kAdminPalette.building : kAdminPalette.inactive,
          ),
          title: Text(building['name'] as String? ?? ''),
          subtitle: Text(
            [
              place['name'] as String? ?? l10n.commonUnknownUniversity,
              if (building['floors'] case final int floors)
                l10n.adminMapFloorsLabel(floors),
              l10n.adminAnchorCountLabel(
                _anchorPointsOf(building['id'] as String).length,
              ),
              if (!active) l10n.adminMapInactive,
            ].join(' · '),
          ),
        ),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.edit_outlined),
              label: Text(l10n.commonEdit),
              onPressed: () {
                close();
                _editBuilding(building);
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.list),
              label: Text(l10n.adminMapOpenPointsList),
              onPressed: () {
                close();
                setState(() {
                  _anchorPointsBuildingFilterId = building['id'] as String;
                  _anchorPointsPlaceFilterId = building['place_id'] as String?;
                });
                _tabController.animateTo(_kPoints);
              },
            ),
          ],
        ),
      ],
    );
  }

  /// The status chips and filters: one test for the list and the map.
  bool Function(Map<String, dynamic>) _pointFilter() {
    final withPhotos = {
      for (final photo in _photos) photo['anchor_point_id'] as String?,
    }.whereType<String>().toSet();
    final connected = {
      for (final c in _connections) ...[
        c['anchor_point_a_id'] as String?,
        c['anchor_point_b_id'] as String?,
      ],
    }.whereType<String>().toSet();
    return (p) =>
        _anchorFilters.matches(p, withPhotos: withPhotos, connected: connected);
  }

  /// The Map section (C2): universities, then buildings, then points.
  Widget _mapTab() {
    final l10n = AppLocalizations.of(context)!;
    return _withMoveControls(
      MapHome(
        places: _places,
        buildings: _buildings,
        points: _anchorPoints,
        connections: _connections,
        scope: _mapScope,
        onScopeChanged: (scope) => setState(() => _mapScope = scope),
        movingPointId: _movingPoint?['id'] as String?,
        moveTarget: _moveTarget,
        onMoveTargetTapped: (target) => setState(() => _moveTarget = target),
        // Below the move or connect banner.
        controlsTop: _movingPoint == null && !_connecting ? 8 : 72,
        connecting: _connecting,
        onConnectingChanged: (on) => setState(() {
          _connecting = on;
          _connectFromId = null;
          _movingPoint = null;
          _moveTarget = null;
        }),
        selectedPointId: _connectFromId,
        onConnectTap: _onConnectTap,
        pointFilter: _pointFilter(),
        focus: _mapFocus,
        sidePanel: _permanentDrawer,
        pointName: (point) => _pointLabel(l10n, point),
        details: (context, item, close) => switch (item) {
          PlaceHit(:final place) => _placeDetails(place, close),
          BuildingHit(:final building) => _buildingDetails(building, close),
          PointHit(:final point) => _pointDetails(point, close),
          ConnectionHit(:final connection) => _connectionDetails(
            connection,
            close,
          ),
        },
      ),
    );
  }

  /// Saves the position picked in move mode. A verified point is re-sent
  /// to photo search with the new coordinates; the backend recomputes its
  /// connections' distances.
  Future<void> _confirmMove() async {
    final point = _movingPoint;
    final target = _moveTarget;
    if (point == null || target == null) return;
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final name = _pointLabel(l10n, point);
    try {
      final saved = await saveAnchorPoint(
        context,
        _mapApi,
        id: point['id'] as String,
        original: point,
        changes: {
          'latitude': target.latitude,
          'longitude': target.longitude,
          // The phone's GPS altitude was for where it was first captured.
          'altitude': null,
        },
        name: name,
      );
      if (!saved) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.mapConflictKeptTheirs(name))),
        );
        if (!mounted) return;
        setState(() {
          _movingPoint = null;
          _moveTarget = null;
        });
        await _loadData();
        return;
      }
      if (point['status'] == 'verified') {
        final photos = _photosOf(point['id'] as String);
        if (photos.isNotEmpty) {
          await indexAnchorPoint(_aiTrainingApi, {
            ...point,
            'latitude': target.latitude,
            'longitude': target.longitude,
          }, photos);
        }
      }
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.adminAnchorMovedSnackbar(name))),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.editAnchorErrorUpdateFailed(
              friendlyApiErrorMessage(context, e),
            ),
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _movingPoint = null;
      _moveTarget = null;
    });
    await _loadData();
  }

  /// [map] with the move banner and its Save button over it, while a point
  /// is being moved.
  Widget _withMoveControls(Widget map) {
    final l10n = AppLocalizations.of(context)!;
    final moving = _movingPoint;
    return Stack(
      children: [
        map,
        if (moving != null)
          Positioned(
            left: 8,
            right: 8,
            top: 8,
            child: Material(
              elevation: 2,
              borderRadius: BorderRadius.circular(8),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          l10n.adminAnchorMoveBanner(_pointLabel(l10n, moving)),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _movingPoint = null;
                        _moveTarget = null;
                      }),
                      child: Text(l10n.commonCancel),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (moving != null && _moveTarget != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 96,
            child: FilledButton.icon(
              icon: const Icon(Icons.check),
              label: Text(l10n.adminAnchorMoveConfirm),
              onPressed: _confirmMove,
            ),
          ),
      ],
    );
  }

  /// The metadata filters sheet for the Anchor points tab. Changes apply
  /// right away to the list and map behind it.
  /// [scoped]: the points the list or map shows before these filters, for
  /// the status counts; [buildingId] for the floors offered.
  Future<void> _showAnchorFilters(
    List<Map<String, dynamic>> scoped,
    String? buildingId,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    int count(String? status) => status == null
        ? scoped.length
        : scoped.where((p) => p['status'] == status).length;
    final scopedBuilding = _buildings.firstWhere(
      (b) => b['id'] == buildingId,
      orElse: () => const {},
    );
    final maxFloors = scopedBuilding.isNotEmpty
        ? (scopedBuilding['floors'] as int? ?? 1)
        : _buildings.fold<int>(
            1,
            (most, b) => (b['floors'] as int? ?? 1) > most
                ? (b['floors'] as int? ?? 1)
                : most,
          );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final f = _anchorFilters;
          void update(AnchorFilters next) {
            setState(() => _anchorFilters = next);
            setSheetState(() {});
          }

          Widget section(String title, List<Widget> chips) => Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 4, children: chips),
              ],
            ),
          );
          Widget choice<T>(
            String label,
            T? value,
            T? current,
            void Function(T?) set,
          ) => ChoiceChip(
            label: Text(label),
            selected: value == current,
            onSelected: (_) => set(value),
          );

          final typesInCategory = f.category == null
              ? const <LocationType>[]
              : kLocationTypeCatalog
                    .where((t) => t.category == f.category)
                    .toList();

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.8,
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.adminFiltersTitle,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (!f.isEmpty)
                        TextButton(
                          onPressed: () => update(AnchorFilters.none),
                          child: Text(l10n.adminFiltersClear),
                        ),
                    ],
                  ),
                  section(l10n.adminFilterStatus, [
                    for (final (value, label) in [
                      (null, l10n.commonStatusAll),
                      ('pending', l10n.commonStatusPending),
                      ('verified', l10n.commonStatusVerified),
                      ('rejected', l10n.commonStatusRejected),
                    ])
                      choice<String>(
                        l10n.adminStatusChipLabel(label, count(value)),
                        value,
                        f.status,
                        (v) => update(f.copyWith(status: v)),
                      ),
                  ]),
                  section(l10n.adminFilterCategory, [
                    choice<LocationCategory>(
                      l10n.adminFilterAny,
                      null,
                      f.category,
                      (v) =>
                          update(f.copyWith(category: v, locationTypeId: null)),
                    ),
                    for (final category in LocationCategory.values)
                      choice<LocationCategory>(
                        locationCategoryLabel(l10n, category),
                        category,
                        f.category,
                        (v) => update(
                          f.copyWith(category: v, locationTypeId: null),
                        ),
                      ),
                  ]),
                  if (typesInCategory.isNotEmpty)
                    section(l10n.adminFilterType, [
                      choice<int>(
                        l10n.adminFilterAny,
                        null,
                        f.locationTypeId,
                        (v) => update(f.copyWith(locationTypeId: v)),
                      ),
                      for (final type in typesInCategory)
                        choice<int>(
                          locationTypeLabel(l10n, type.key),
                          type.id,
                          f.locationTypeId,
                          (v) => update(f.copyWith(locationTypeId: v)),
                        ),
                    ]),
                  section(l10n.adminFilterFloor, [
                    choice<int>(
                      l10n.adminFilterAny,
                      null,
                      f.floor,
                      (v) => update(f.copyWith(floor: v)),
                    ),
                    for (var floor = 0; floor < maxFloors; floor++)
                      choice<int>(
                        l10n.commonFloorOption(floor + 1),
                        floor,
                        f.floor,
                        (v) => update(f.copyWith(floor: v)),
                      ),
                  ]),
                  section(l10n.adminFilterPlace, [
                    for (final (label, value) in [
                      (l10n.adminFilterAny, null),
                      (l10n.adminFilterIndoor, 'indoor'),
                      (l10n.adminFilterOutdoor, 'outdoor'),
                      (l10n.adminFilterNotSet, 'unset'),
                    ])
                      choice<String>(
                        label,
                        value,
                        f.indoor,
                        (v) => update(f.copyWith(indoor: v)),
                      ),
                  ]),
                  section(l10n.adminFilterLighting, [
                    for (final (label, value) in [
                      (l10n.adminFilterAny, null),
                      (l10n.commonLightingBright, 'bright'),
                      (l10n.commonLightingModerate, 'moderate'),
                      (l10n.commonLightingDim, 'dim'),
                      (l10n.adminFilterNotSet, 'unset'),
                    ])
                      choice<String>(
                        label,
                        value,
                        f.lighting,
                        (v) => update(f.copyWith(lighting: v)),
                      ),
                  ]),
                  section(l10n.adminFilterPhotos, [
                    for (final (label, value) in [
                      (l10n.adminFilterAny, null),
                      (l10n.adminFilterHas, true),
                      (l10n.adminFilterHasNone, false),
                    ])
                      choice<bool>(
                        label,
                        value,
                        f.hasPhotos,
                        (v) => update(f.copyWith(hasPhotos: v)),
                      ),
                  ]),
                  section(l10n.adminFilterConnections, [
                    for (final (label, value) in [
                      (l10n.adminFilterAny, null),
                      (l10n.adminFilterHas, true),
                      (l10n.adminFilterHasNone, false),
                    ])
                      choice<bool>(
                        label,
                        value,
                        f.hasConnections,
                        (v) => update(f.copyWith(hasConnections: v)),
                      ),
                  ]),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// The Anchor points list's university and building scope.
  List<Map<String, dynamic>> get _anchorPointsScoped => pointsInScope(
    MapScope(
      placeId: _anchorPointsPlaceFilterId,
      buildingId: _anchorPointsBuildingFilterId,
    ),
    buildings: _buildings,
    points: _anchorPoints,
  );

  Widget _anchorPointsTab() {
    final l10n = AppLocalizations.of(context)!;
    final withPhotos = {
      for (final photo in _photos) photo['anchor_point_id'] as String?,
    }.whereType<String>().toSet();
    final connected = {
      for (final c in _connections) ...[
        c['anchor_point_a_id'] as String?,
        c['anchor_point_b_id'] as String?,
      ],
    }.whereType<String>().toSet();
    final buildingsById = {for (final b in _buildings) b['id'] as String: b};
    final scopedBuilding = _anchorPointsBuildingFilterId != null
        ? buildingsById[_anchorPointsBuildingFilterId]
        : null;
    final buildingScoped = _anchorPointsScoped;
    final filtered =
        buildingScoped
            .where(
              (p) =>
                  _anchorFilters.matches(
                    p,
                    withPhotos: withPhotos,
                    connected: connected,
                  ) &&
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
        ScopeDropdowns(
          places: _places,
          buildings: _buildings,
          placeId: _anchorPointsPlaceFilterId,
          buildingId: _anchorPointsBuildingFilterId,
          onChanged: (placeId, buildingId) => setState(() {
            _anchorPointsPlaceFilterId = placeId;
            _anchorPointsBuildingFilterId = buildingId;
          }),
        ),
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
                  padding: EdgeInsets.only(bottom: _fabClearance),
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
                          : Icon(
                              Icons.location_pin,
                              color: kAdminPalette.verified,
                            ),
                      title: Text(anchorDisplayName(l10n, point)),
                      subtitle: Text(
                        '${building?['name'] as String? ?? l10n.commonUnknownBuilding} · '
                        '${l10n.adminStatusLabel(anchorStatusLabel(l10n, point['status'] as String? ?? 'unknown'))} · '
                        '${l10n.adminPhotoCountLabel(photos.length)}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _statusToggleButton(point),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: l10n.commonEdit,
                            onPressed: () => _editAnchorPoint(point),
                          ),
                          PopupMenuButton<String>(
                            tooltip: l10n.adminMoreActionsTooltip,
                            onSelected: (choice) => choice == 'photo'
                                ? _addPhoto(point)
                                : _deleteAnchorPoint(point),
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'photo',
                                child: ListTile(
                                  leading: const Icon(
                                    Icons.add_a_photo_outlined,
                                  ),
                                  title: Text(l10n.adminAddPhotoTooltip),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: ListTile(
                                  leading: const Icon(Icons.delete_outline),
                                  title: Text(l10n.commonDelete),
                                ),
                              ),
                            ],
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

    // Narrowed to a university or building: either end inside counts.
    final placeBuildings = {
      for (final b in _buildings)
        if (b['place_id'] == _connectionsPlaceId) b['id'],
    };
    bool inside(String? anchorPointId) {
      final buildingId = anchorPointsById[anchorPointId]?['building_id'];
      if (_connectionsBuildingId != null) {
        return buildingId == _connectionsBuildingId;
      }
      return _connectionsPlaceId == null || placeBuildings.contains(buildingId);
    }

    final filtered = _connections.where((c) {
      if (c['pending'] == true) return false;
      final a = c['anchor_point_a_id'] as String?;
      final b = c['anchor_point_b_id'] as String?;
      if (!inside(a) && !inside(b)) return false;
      if (!_connectionFilters.matches(c, anchorPointsById)) return false;
      final aDesc = describe(a).toLowerCase();
      final bDesc = describe(b).toLowerCase();
      return aDesc.contains(_connectionQuery) ||
          bDesc.contains(_connectionQuery);
    }).toList();

    return Column(
      children: [
        ScopeDropdowns(
          places: _places,
          buildings: _buildings,
          placeId: _connectionsPlaceId,
          buildingId: _connectionsBuildingId,
          onChanged: (placeId, buildingId) => setState(() {
            _connectionsPlaceId = placeId;
            _connectionsBuildingId = buildingId;
          }),
        ),
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
                  padding: EdgeInsets.only(bottom: _fabClearance),
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
                      leading: Icon(
                        Icons.timeline,
                        color: kAdminPalette.connectionActive,
                      ),
                      title: Text(
                        '${describe(connection['anchor_point_a_id'] as String?)} '
                        '↔ ${describe(connection['anchor_point_b_id'] as String?)}',
                      ),
                      subtitle: Text(
                        '${aBuilding?['name'] as String? ?? l10n.commonUnknownBuilding} / '
                        '${bBuilding?['name'] as String? ?? l10n.commonUnknownBuilding}'
                        '${distance != null ? ' · ${distance}m' : ''}'
                        '${(connection['notes'] as String? ?? '').isEmpty ? '' : '\n⚠ ${connection['notes']}'}',
                      ),
                      onTap: () => _editConnectionWarning(connection),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.map_outlined),
                            tooltip: l10n.adminMapShowOnMap,
                            onPressed: () =>
                                _showOnMap(ConnectionHit(connection)),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: l10n.commonDelete,
                            onPressed: () => _deleteConnection(connection),
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

  double get _fabClearance => fabClearance(context);

  Future<void> _showConnectionFilters() async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final f = _connectionFilters;
          void update(ConnectionFilters next) {
            setState(() => _connectionFilters = next);
            setSheetState(() {});
          }

          Widget section(
            String title,
            bool? current,
            void Function(bool?) set,
          ) {
            Widget choice(String label, bool? value) => ChoiceChip(
              label: Text(label),
              selected: value == current,
              onSelected: (_) => set(value),
            );
            return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [
                      choice(l10n.adminFilterAny, null),
                      choice(l10n.adminFilterYes, true),
                      choice(l10n.adminFilterNo, false),
                    ],
                  ),
                ],
              ),
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.adminConnectionFiltersTitle,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (!f.isEmpty)
                        TextButton(
                          onPressed: () => update(ConnectionFilters.none),
                          child: Text(l10n.adminFiltersClear),
                        ),
                    ],
                  ),
                  section(
                    l10n.adminConnectionFilterLong,
                    f.long,
                    (v) => update(f.copyWith(long: v)),
                  ),
                  section(
                    l10n.adminConnectionFilterWarning,
                    f.hasWarning,
                    (v) => update(f.copyWith(hasWarning: v)),
                  ),
                  section(
                    l10n.adminConnectionChangesFloor,
                    f.changesFloor,
                    (v) => update(f.copyWith(changesFloor: v)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// The Filters button, bottom left, with how many are on: the Map, the
  /// Anchor points list and the Connections tab.
  Widget? _filtersFab() {
    final l10n = AppLocalizations.of(context)!;
    final (int count, VoidCallback open) = switch (_tabController.index) {
      _kMap => (
        _anchorFilters.activeCount,
        () => _showAnchorFilters(
          pointsInScope(
            _mapScope,
            buildings: _buildings,
            points: _anchorPoints,
          ),
          _mapScope.buildingId,
        ),
      ),
      _kPoints => (
        _anchorFilters.activeCount,
        () => _showAnchorFilters(
          _anchorPointsScoped,
          _anchorPointsBuildingFilterId,
        ),
      ),
      _kConnections => (_connectionFilters.activeCount, _showConnectionFilters),
      _ => (0, () {}),
    };
    if (_tabController.index != _kMap &&
        _tabController.index != _kPoints &&
        _tabController.index != _kConnections) {
      return null;
    }
    return FloatingActionButton(
      heroTag: 'filters-fab',
      tooltip: count == 0
          ? l10n.adminFiltersButton
          : l10n.adminFiltersButtonCount(count),
      onPressed: open,
      child: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.filter_list),
      ),
    );
  }

  /// Filters bottom left, the add button bottom right.
  Widget? _fabs() {
    final filters = _filtersFab();
    final add = _fab();
    if (filters == null && add == null) return null;
    return FabRow(left: filters, right: add);
  }

  Widget? _fab() {
    final l10n = AppLocalizations.of(context)!;
    switch (_tabController.index) {
      case _kMap:
        // A new point where the admin is looking, in the field.
        return FloatingActionButton(
          heroTag: 'add-fab',
          tooltip: l10n.adminFabNewAnchorPoint,
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CaptureScreen(
                  initialPlaceId: _mapScope.placeId,
                  initialBuildingId: _mapScope.buildingId,
                ),
              ),
            );
            _loadData();
          },
          child: const Icon(Icons.add_a_photo),
        );
      case _kUniversities:
        return FloatingActionButton(
          heroTag: 'add-fab',
          tooltip: l10n.adminFabAddUniversity,
          onPressed: () async {
            await Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AddPlaceScreen()));
            _loadData();
          },
          child: const Icon(Icons.add),
        );
      case _kBuildings:
        return FloatingActionButton(
          heroTag: 'add-fab',
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
      case _kPoints:
        return FloatingActionButton(
          heroTag: 'add-fab',
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
      case _kConnections:
        return FloatingActionButton(
          heroTag: 'add-fab',
          tooltip: l10n.adminFabConnectOnMap,
          onPressed: () {
            _tabController.animateTo(_kMap);
            setState(() {
              // Where the tab is narrowed to; otherwise the map stays where
              // the admin left it.
              final building = _buildings.firstWhere(
                (b) => b['id'] == _connectionsBuildingId,
                orElse: () => const {},
              );
              if (building.isNotEmpty) {
                _mapScope = MapScope.building(building);
              } else if (_connectionsPlaceId != null) {
                _mapScope = MapScope(placeId: _connectionsPlaceId);
              }
              _connecting = true;
              _connectFromId = null;
            });
          },
          child: const Icon(Icons.timeline),
        );
      default:
        // Users tab - no "add" action, accounts are created via
        // signup, not an admin-initiated flow.
        return null;
    }
  }

  List<String> get _sectionTitles {
    final l10n = AppLocalizations.of(context)!;
    return [
      l10n.adminSectionMap,
      l10n.adminSectionUniversities,
      l10n.adminSectionBuildings,
      l10n.adminSectionAnchorPoints,
      l10n.adminSectionConnections,
      l10n.adminUsersTabLabel,
    ];
  }

  /// The tutorial's section for each tab (anchors in `docs/admin-guide/`).
  static const _kGuideSections = [
    'points-map',
    'universities',
    'buildings',
    'anchor-points',
    'connections',
    'users',
  ];

  /// On a wide screen (the web app on a monitor) the drawer stays open as a
  /// side menu instead of sliding over the page.
  static const double _kPermanentDrawerWidth = 900;
  bool _permanentDrawer = false;

  void _closeDrawer() {
    if (!_permanentDrawer) Navigator.of(context).pop();
  }

  /// Mapping mistakes that break navigation, from the loaded lists (see
  /// `capture_checks.dart`). Each opens what needs fixing; nothing shows
  /// when the data is clean.
  List<Widget> _dataHealthTiles(AppLocalizations l10n) {
    if (_loading) return const [];
    final unconnected = verifiedUnconnectedPoints(_anchorPoints, _connections);
    final hidden = namedHiddenPoints(_anchorPoints);
    final long = longConnections(_anchorPoints, _connections);
    final floorChange = floorChangeConnections(_anchorPoints, _connections);
    Widget tile(String text, IconData icon, VoidCallback onTap) => ListTile(
      leading: Icon(icon, color: kAdminPalette.notice),
      title: Text(text, style: TextStyle(color: kAdminPalette.notice)),
      onTap: () {
        _closeDrawer();
        onTap();
      },
    );
    return [
      if (unconnected.isNotEmpty)
        tile(
          l10n.adminHealthUnconnected(unconnected.length),
          Icons.link_off,
          _showUnconnectedVerified,
        ),
      if (hidden.isNotEmpty)
        tile(
          l10n.adminHealthHiddenNamed(hidden.length),
          Icons.visibility_off_outlined,
          () => _showReviewList(
            title: l10n.adminHealthHiddenNamed(hidden.length),
            guideSection: 'pitfall-type',
            hint: l10n.adminHealthHiddenNamedHint,
            items: [
              for (final point in hidden)
                (
                  title: anchorDisplayName(l10n, point),
                  subtitle: [
                    locationTypeLabel(
                      l10n,
                      kLocationTypes[point['location_type_id']] ?? 'other',
                    ),
                    _buildingName(point['building_id'] as String?),
                  ].join(' · '),
                  onTap: () => _showOnMap(PointHit(point)),
                ),
            ],
          ),
        ),
      if (long.isNotEmpty)
        tile(
          l10n.adminHealthLongConnections(long.length),
          Icons.straighten,
          () {
            final byId = {for (final p in _anchorPoints) p['id']: p};
            _showReviewList(
              title: l10n.adminHealthLongConnections(long.length),
              guideSection: 'pitfall-gap',
              hint: l10n.adminHealthLongConnectionsHint,
              items: [
                for (final c in long)
                  (
                    title:
                        '${_pointLabel(l10n, byId[c['anchor_point_a_id']])}'
                        ' ↔ '
                        '${_pointLabel(l10n, byId[c['anchor_point_b_id']])}',
                    subtitle: l10n.adminHealthConnectionSubtitle(
                      anchorDistance(
                        byId[c['anchor_point_a_id']]!,
                        byId[c['anchor_point_b_id']]!,
                      )!.toStringAsFixed(0),
                    ),
                    onTap: () => _showOnMap(ConnectionHit(c)),
                  ),
              ],
            );
          },
        ),
      if (floorChange.isNotEmpty)
        tile(l10n.adminHealthFloorChange(floorChange.length), Icons.stairs, () {
          final byId = {for (final p in _anchorPoints) p['id']: p};
          _showReviewList(
            title: l10n.adminHealthFloorChange(floorChange.length),
            guideSection: 'pitfall-floor',
            hint: l10n.adminHealthFloorChangeHint,
            items: [
              for (final c in floorChange)
                (
                  title:
                      '${_pointLabel(l10n, byId[c['anchor_point_a_id']])}'
                      ' ↔ '
                      '${_pointLabel(l10n, byId[c['anchor_point_b_id']])}',
                  subtitle: l10n.adminHealthConnectionSubtitle(
                    (anchorDistance(
                              byId[c['anchor_point_a_id']]!,
                              byId[c['anchor_point_b_id']]!,
                            ) ??
                            0)
                        .toStringAsFixed(0),
                  ),
                  onTap: () => _showOnMap(ConnectionHit(c)),
                ),
            ],
          );
        }),
    ];
  }

  /// A point's name with its building: names don't repeat it.
  String _pointLabel(AppLocalizations l10n, Map<String, dynamic>? point) {
    for (final building in _buildings) {
      if (building['id'] == point?['building_id']) {
        return anchorLabel(l10n, point, building['name'] as String?);
      }
    }
    return anchorDisplayName(l10n, point);
  }

  String _buildingName(String? id) =>
      _buildings.firstWhere(
            (b) => b['id'] == id,
            orElse: () => const {},
          )['name']
          as String? ??
      '';

  /// Verified points with no connection, each opening on the map to fix.
  void _showUnconnectedVerified() {
    final l10n = AppLocalizations.of(context)!;
    final points = verifiedUnconnectedPoints(_anchorPoints, _connections);
    _showReviewList(
      title: l10n.adminHealthUnconnected(points.length),
      guideSection: 'pitfall-unconnected',
      hint: l10n.adminHealthUnconnectedHint,
      items: [
        for (final point in points)
          (
            title: anchorDisplayName(l10n, point),
            subtitle: _buildingName(point['building_id'] as String?),
            onTap: () => _showOnMap(PointHit(point)),
          ),
      ],
    );
  }

  Future<void> _showReviewList({
    required String title,
    required String hint,
    required List<ReviewItem> items,
    String? guideSection,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, controller) => ReviewList(
        controller: controller,
        title: title,
        hint: hint,
        items: items,
        guideSection: guideSection,
      ),
    ),
  );

  Widget _drawer() {
    final l10n = AppLocalizations.of(context)!;
    Widget item(int index, IconData icon, Color color, String label) {
      return ListTile(
        leading: Icon(icon, color: color),
        title: Text(label),
        selected: _tabController.index == index,
        onTap: () {
          _tabController.animateTo(index);
          _closeDrawer();
        },
      );
    }

    return Drawer(
      // Part of the page on a wide screen (see _scaffold).
      elevation: _permanentDrawer ? 0 : null,
      shape: _permanentDrawer ? const RoundedRectangleBorder() : null,
      child: DrawerList(
        children: [
          // A compact header: DrawerHeader's fixed height left a band of
          // empty space under the email.
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
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
          ),
          const Divider(height: 1),
          // The tutorial is a page next to the web app, for reading beside it.
          if (kIsWeb)
            ListTile(
              leading: const Icon(Icons.menu_book, color: Colors.blue),
              title: Text(l10n.adminGuide),
              onTap: () {
                _closeDrawer();
                openAdminGuide(context);
              },
            ),
          item(_kMap, Icons.map_outlined, Colors.blue, l10n.adminSectionMap),
          item(
            _kUniversities,
            Icons.flag,
            kAdminPalette.university,
            l10n.adminSectionUniversities,
          ),
          item(
            _kBuildings,
            Icons.apartment,
            kAdminPalette.building,
            l10n.adminSectionBuildings,
          ),
          item(
            _kPoints,
            Icons.location_pin,
            kAdminPalette.verified,
            l10n.adminSectionAnchorPoints,
          ),
          item(
            _kConnections,
            Icons.timeline,
            kAdminPalette.connectionActive,
            l10n.adminSectionConnections,
          ),
          item(_kUsers, Icons.people, Colors.indigo, l10n.adminUsersTabLabel),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.my_location, color: Colors.teal),
            title: Text(l10n.adminSessions),
            onTap: () {
              _closeDrawer();
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SessionsScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.comment_outlined, color: Colors.teal),
            title: Text(l10n.feedbackScreenTitle),
            onTap: () {
              _closeDrawer();
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const FeedbackScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.manage_search, color: Colors.teal),
            title: Text(l10n.adminReindexMenu),
            subtitle: (_unsearchablePhotos ?? 0) > 0
                ? Text(
                    l10n.adminReindexUnsearchable(_unsearchablePhotos!),
                    style: const TextStyle(color: Colors.red),
                  )
                : null,
            enabled: !_reindexing && !_loading,
            onTap: () {
              _closeDrawer();
              _reindexVerified();
            },
          ),
          ..._dataHealthTiles(l10n),
          // Trips need the phone's camera and sensors.
          if (!kIsWeb)
            ListTile(
              leading: const Icon(
                Icons.visibility_outlined,
                color: Colors.teal,
              ),
              title: Text(l10n.adminTestAsUser),
              onTap: () {
                _closeDrawer();
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
    return LayoutBuilder(
      builder: (context, constraints) {
        _permanentDrawer = constraints.maxWidth >= _kPermanentDrawerWidth;
        final scaffold = _scaffoldBody(l10n);
        if (!_permanentDrawer) return scaffold;
        return Row(
          children: [
            SizedBox(width: 280, child: _drawer()),
            const VerticalDivider(width: 1),
            Expanded(child: scaffold),
          ],
        );
      },
    );
  }

  Widget _scaffoldBody(AppLocalizations l10n) {
    return Scaffold(
      drawer: _permanentDrawer ? null : _drawer(),
      appBar: AppBar(
        title: Text(_sectionTitles[_tabController.index]),
        actions: [
          if (kIsWeb)
            IconButton(
              icon: const Icon(Icons.help_outline),
              tooltip: l10n.adminGuideSectionTooltip,
              onPressed: () => openAdminGuide(
                context,
                section: _kGuideSections[_tabController.index],
              ),
            ),
          if (_tabController.index == _kConnections)
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
            // Same pull-down spinner as a pull, so a reload is visible.
            onPressed: _loading ? null : () => _refreshKey.currentState?.show(),
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
            tooltip: l10n.commonLogOut,
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      floatingActionButton: _fabs(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              key: _refreshKey,
              onRefresh: _refresh,
              // The tabs' lists sit inside TabBarView's horizontal pager,
              // so their scroll notifications arrive at depth 1 - the
              // default predicate (depth 0 only) made pulling do nothing.
              notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
              child: _error != null
                  ? ScrollableMessage(_error!)
                  : TabBarView(
                      controller: _tabController,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        _mapTab(),
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

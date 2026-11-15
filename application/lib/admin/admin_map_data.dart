import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../services/admin_lists.dart';
import '../services/anchor_indexing.dart';
import '../services/api_service.dart';
import '../services/map_sync.dart';

/// The admin home's map data (Phase D): the five lists, loaded in full on
/// opening and on pull-to-refresh, then kept fresh from `GET /changes`
/// (A5), and how many verified photos aren't searchable. Listeners hear
/// every change.
class AdminMapData extends ChangeNotifier {
  AdminMapData({required this.mapApi, required this.aiTrainingApi});

  final MapManagementApi mapApi;
  final AiTrainingApi aiTrainingApi;

  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _buildings = [];
  List<Map<String, dynamic>> _anchorPoints = [];
  List<Map<String, dynamic>> _photos = [];
  List<Map<String, dynamic>> _connections = [];
  bool _loading = true;
  Object? _loadError;
  int? _unsearchablePhotos;

  /// What changed since, for GET /changes (A5): set from the server's own
  /// clock after a full load. Null when the server can't answer it yet, and
  /// then every refresh is a full one.
  String? _since;
  Future<void>? _syncing;
  bool _disposed = false;

  List<Map<String, dynamic>> get places => _places;
  List<Map<String, dynamic>> get buildings => _buildings;
  List<Map<String, dynamic>> get anchorPoints => _anchorPoints;
  List<Map<String, dynamic>> get photos => _photos;
  List<Map<String, dynamic>> get connections => _connections;

  /// Until the first full load ends, well or not.
  bool get loading => _loading;

  /// Why the last full load failed, or null.
  Object? get loadError => _loadError;

  /// Verified photos missing from the photo index (null: unknown).
  int? get unsearchablePhotos => _unsearchablePhotos;
  set unsearchablePhotos(int? count) {
    _unsearchablePhotos = count;
    _changed();
  }

  /// Connect mode's optimistic lines: shown before they're saved.
  set connections(List<Map<String, dynamic>> rows) {
    _connections = rows;
    _changed();
  }

  AdminLists get lists => AdminLists(
    places: _places,
    buildings: _buildings,
    anchorPoints: _anchorPoints,
    photos: _photos,
    connections: _connections,
  );

  /// All five lists: on opening, on pull-to-refresh, and as a fallback.
  Future<void> loadAll() async {
    // Asked before the lists, so nothing changed between them is missed.
    final since = _serverSince();
    try {
      final results = await Future.wait([
        mapApi.get('/places'),
        mapApi.get('/buildings'),
        mapApi.get('/anchor-points'),
        mapApi.get('/anchor-point-photos'),
        mapApi.get('/anchor-point-connections'),
      ]);
      if (_disposed) return;
      List<Map<String, dynamic>> rows(Object? list) =>
          (list as List? ?? []).cast<Map<String, dynamic>>();
      _places = rows(results[0]);
      _buildings = rows(results[1]);
      _anchorPoints = rows(results[2]);
      _photos = rows(results[3]);
      _connections = rows(results[4]);
      _loading = false;
      _loadError = null;
      _changed();
      _since = await since;
      refreshIndexStatus();
    } catch (e) {
      // Not only ApiException: a malformed response must end the spinner too.
      if (_disposed) return;
      _loadError = e;
      _loading = false;
      _changed();
    }
  }

  /// Fetches and merges `/changes`, one at a time, and returns how many
  /// came in that weren't already held. [announce] is the 30 s timer's: it
  /// never falls back to a full load, and leaves the index status alone.
  Future<int> sync({required bool announce}) async {
    while (_syncing != null) {
      await _syncing;
    }
    final since = _since;
    if (since == null) {
      // The server can't answer /changes (yet): reload as before, but not
      // every 30 s.
      if (!announce) await loadAll();
      return 0;
    }
    final done = Completer<void>();
    _syncing = done.future;
    try {
      final changes = await mapApi.get(
        '/changes?since=${Uri.encodeQueryComponent(since)}',
      );
      if (_disposed || changes is! Map<String, dynamic>) return 0;
      if (changes['full'] == true) {
        await loadAll();
        return 0;
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
      _places = merged.lists.places;
      _buildings = merged.lists.buildings;
      _anchorPoints = merged.lists.anchorPoints;
      _photos = merged.lists.photos;
      _connections = merged.lists.connections;
      _since = changes['next_since'] as String?;
      _changed();
      if (!announce) refreshIndexStatus();
      return merged.newChanges;
    } on ApiException {
      // Something is off: fall back to what always worked.
      if (!announce && !_disposed) await loadAll();
      return 0;
    } finally {
      _syncing = null;
      done.complete();
    }
  }

  /// How many verified photos aren't searchable, for the drawer warning.
  /// Best effort: unknown leaves the warning off.
  Future<void> refreshIndexStatus() async {
    final indexed = await fetchIndexedPhotoIds(aiTrainingApi);
    if (_disposed || indexed == null) return;
    unsearchablePhotos = unsearchablePhotoCount(
      _anchorPoints,
      lists.photosOf,
      indexed,
    );
  }

  /// The server's clock, to ask /changes from: a phone's clock can be off.
  /// Null when /changes isn't there, as before the migration.
  Future<String?> _serverSince() async {
    try {
      final since = clock.now().toUtc().subtract(const Duration(minutes: 5));
      final changes = await mapApi.get(
        '/changes?since=${Uri.encodeQueryComponent(since.toIso8601String())}',
      );
      return changes is Map ? changes['next_since'] as String? : null;
    } on ApiException {
      return null;
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

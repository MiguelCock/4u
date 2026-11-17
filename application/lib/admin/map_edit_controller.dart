import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import '../services/connect_chain.dart';
import 'admin_map_data.dart';

/// How saving a connection ended ([MapEditController.save]), for the admin
/// home to say.
sealed class ConnectSave {
  const ConnectSave();
}

/// Saved; the grey line became a real one.
class ConnectSaved extends ConnectSave {
  const ConnectSaved(this.pair);
  final ConnectPair pair;
}

/// Not saved: nobody is signed in.
class ConnectNotSignedIn extends ConnectSave {
  const ConnectNotSignedIn();
}

/// The same pair is already being saved: nothing was done.
class ConnectAlreadySaving extends ConnectSave {
  const ConnectAlreadySaving();
}

/// The server refused it (409: already connected); the grey line is gone.
class ConnectFailed extends ConnectSave {
  const ConnectFailed(this.error);
  final ApiException error;
}

/// Editing on the admin map (#270): Connect mode (C3) and moving a point.
/// Holds which point is selected and which is moving, and saves connections
/// optimistically into [AdminMapData]. The admin home says what happened
/// and saves a move (that needs its dialogs).
///
/// It came out of `AdminHomeScreen`, where this state sat with every tab's.
class MapEditController extends ChangeNotifier {
  MapEditController({
    required this._api,
    required this._data,
    required this._userId,
  });

  final MapManagementApi _api;
  final AdminMapData _data;
  final String? Function() _userId;
  bool _disposed = false;

  /// Connect mode is on.
  bool connecting = false;

  /// The first point of the next connection.
  String? connectFromId;

  /// The point being moved, and the new spot picked for it.
  Map<String, dynamic>? movingPoint;
  LatLng? moveTarget;

  /// The pairs ([connectionPairKey]) still being saved.
  final Set<String> _pendingPairs = {};

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Ends a move: no point being moved, no new spot.
  void clearMove() {
    movingPoint = null;
    moveTarget = null;
    _changed();
  }

  void startMove(Map<String, dynamic> point) {
    movingPoint = point;
    moveTarget = null;
    _changed();
  }

  void pickMoveTarget(LatLng target) {
    moveTarget = target;
    _changed();
  }

  /// Connect mode, with [point] as the first of the pair.
  void connectFrom(Map<String, dynamic> point) {
    movingPoint = null;
    moveTarget = null;
    connecting = true;
    connectFromId = point['id'] as String?;
    _changed();
  }

  /// Connect mode switched on or off: no point selected, no move.
  void setConnecting(bool on) {
    connecting = on;
    connectFromId = null;
    movingPoint = null;
    moveTarget = null;
    _changed();
  }

  /// No first point any more; connect mode stays.
  void releaseSelection() {
    connectFromId = null;
    _changed();
  }

  /// Left the map: a move and Connect mode belong to it.
  void leaveMap() {
    movingPoint = null;
    moveTarget = null;
    connecting = false;
    connectFromId = null;
    _changed();
  }

  /// A point tapped in Connect mode: selects, deselects or moves on, and
  /// returns the step ([connectTap]). A [ConnectPair] is for [save].
  ConnectStep tap(Map<String, dynamic> point) {
    final step = connectTap(
      selectedId: connectFromId,
      tapped: point,
      connections: _data.connections,
      pointsById: {for (final p in _data.anchorPoints) p['id'] as String: p},
    );
    switch (step) {
      case ConnectSelect(:final id) || ConnectMoveOn(:final id):
        connectFromId = id;
        _changed();
      case ConnectDeselect():
        connectFromId = null;
        _changed();
      case ConnectRefused() || ConnectPair():
        break;
    }
    return step;
  }

  /// Saves [pair], optimistically: the line shows (dotted grey) and the
  /// selection moves on to its far end at once, so the next tap works while
  /// this one saves; only the same pair waits.
  Future<ConnectSave> save(ConnectPair pair) async {
    final userId = _userId();
    if (userId == null) return const ConnectNotSignedIn();
    final key = connectionPairKey(pair.fromId, pair.toId);
    if (_pendingPairs.contains(key)) return const ConnectAlreadySaving();
    final pending = <String, dynamic>{
      'id': 'pending-$key',
      'anchor_point_a_id': pair.fromId,
      'anchor_point_b_id': pair.toId,
      'pending': true,
    };
    _pendingPairs.add(key);
    connectFromId = pair.toId;
    _data.connections = [..._data.connections, pending];
    _changed();
    try {
      final result = await _api.post('/anchor-point-connections', {
        'anchor_point_a_id': pair.fromId,
        'anchor_point_b_id': pair.toId,
        'created_by': userId,
      });
      final created = result is List && result.isNotEmpty
          ? (result.first as Map).cast<String, dynamic>()
          : null;
      _data.connections = [
        for (final c in _data.connections)
          // The sync may have brought the saved row already.
          if (!identical(c, pending) &&
              (created == null || c['id'] != created['id']))
            c,
        created ?? {...pending, 'pending': false},
      ];
      return ConnectSaved(pair);
    } on ApiException catch (e) {
      _data.connections = [
        for (final c in _data.connections)
          if (!identical(c, pending)) c,
      ];
      return ConnectFailed(e);
    } finally {
      _pendingPairs.remove(key);
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

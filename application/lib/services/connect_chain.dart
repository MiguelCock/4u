/// What a tap on a point does while connecting on the map: the Connect
/// screen's decisions, without the saving. Pure, so it's unit-tested.
library;

import 'capture_checks.dart';

/// The outcome of tapping a point in connect mode.
sealed class ConnectStep {
  const ConnectStep();
}

/// Nothing was selected: [id] is now.
class ConnectSelect extends ConnectStep {
  final String id;
  const ConnectSelect(this.id);
}

/// The selected point was tapped again: nothing is selected now.
class ConnectDeselect extends ConnectStep {
  const ConnectDeselect();
}

/// The pair is already connected: the selection just moves to [id], so a
/// chain along a corridor carries on across an existing line.
class ConnectMoveOn extends ConnectStep {
  final String id;
  const ConnectMoveOn(this.id);
}

/// The pair breaks a rule (too long, a floor change without stairs): nothing
/// is sent and the selection stays, so a mistaken far tap doesn't lose the
/// place in the chain.
class ConnectRefused extends ConnectStep {
  final String fromId;
  final String toId;
  final ConnectionProblem problem;
  final double? distance;
  const ConnectRefused(this.fromId, this.toId, this.problem, this.distance);
}

/// Save a connection from [fromId] to [toId]; [toId] becomes the selection.
class ConnectPair extends ConnectStep {
  final String fromId;
  final String toId;
  final double? distance;

  /// Over [kConnectionWarnMeters]: allowed, but said and felt more strongly.
  bool get long => distance != null && distance! > kConnectionWarnMeters;

  const ConnectPair(this.fromId, this.toId, this.distance);
}

/// The same key for a pair either way round.
String connectionPairKey(String a, String b) =>
    a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';

/// What tapping [tapped] does with [selectedId] selected, given the
/// [connections] there are (pending ones included) and the points by id.
ConnectStep connectTap({
  required String? selectedId,
  required Map<String, dynamic> tapped,
  required Iterable<Map<String, dynamic>> connections,
  required Map<String, Map<String, dynamic>> pointsById,
}) {
  final id = tapped['id'] as String;
  final fromId = selectedId;
  if (fromId == null) return ConnectSelect(id);
  if (fromId == id) return const ConnectDeselect();
  final key = connectionPairKey(fromId, id);
  final connected = connections.any(
    (c) =>
        connectionPairKey(
          c['anchor_point_a_id'] as String? ?? '',
          c['anchor_point_b_id'] as String? ?? '',
        ) ==
        key,
  );
  if (connected) return ConnectMoveOn(id);
  final from = pointsById[fromId] ?? {'id': fromId};
  final distance = anchorDistance(from, tapped);
  final problem = connectionProblem(from, tapped);
  if (problem != null) return ConnectRefused(fromId, id, problem, distance);
  return ConnectPair(fromId, id, distance);
}

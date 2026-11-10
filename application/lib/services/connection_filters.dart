import 'capture_checks.dart';
import 'floor_view.dart';

/// Filters for the admin Connections tab. Every field null means "any";
/// filters combine (all must match). Pure, so the rules are unit-tested.
class ConnectionFilters {
  /// Longer than [kConnectionWarnMeters] (or not).
  final bool? long;

  /// With a warning for users (or without).
  final bool? hasWarning;

  /// Between two floors (or on one).
  final bool? changesFloor;

  const ConnectionFilters({this.long, this.hasWarning, this.changesFloor});

  static const none = ConnectionFilters();

  int get activeCount =>
      [long, hasWarning, changesFloor].where((v) => v != null).length;

  bool get isEmpty => activeCount == 0;

  /// [pointsById]: the anchor points, for the ends' floors and positions.
  bool matches(
    Map<String, dynamic> connection,
    Map<String, Map<String, dynamic>> pointsById,
  ) {
    final a = pointsById[connection['anchor_point_a_id']];
    final b = pointsById[connection['anchor_point_b_id']];
    if (long != null) {
      // The stored distance (typed or measured), else the straight line.
      final distance =
          (connection['distance_meters'] as num?)?.toDouble() ??
          (a == null || b == null ? null : anchorDistance(a, b));
      if ((distance != null && distance > kConnectionWarnMeters) != long) {
        return false;
      }
    }
    if (hasWarning != null &&
        (connection['notes'] as String? ?? '').trim().isNotEmpty !=
            hasWarning) {
      return false;
    }
    if (changesFloor != null) {
      final changes = a != null && b != null && pointFloor(a) != pointFloor(b);
      if (changes != changesFloor) return false;
    }
    return true;
  }

  ConnectionFilters copyWith({
    Object? long = _keep,
    Object? hasWarning = _keep,
    Object? changesFloor = _keep,
  }) {
    bool? pick(Object? value, bool? current) =>
        identical(value, _keep) ? current : value as bool?;
    return ConnectionFilters(
      long: pick(long, this.long),
      hasWarning: pick(hasWarning, this.hasWarning),
      changesFloor: pick(changesFloor, this.changesFloor),
    );
  }
}

const Object _keep = Object();

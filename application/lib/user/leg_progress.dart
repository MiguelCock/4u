import 'package:clock/clock.dart';

import '../services/turn_guidance.dart';

/// What the periodic update along a leg should say ([LegProgress.update]).
enum LegUpdate {
  /// Nothing new: the same step count as last time.
  quiet,

  /// Not getting closer: "keep walking", if nothing else was said lately.
  keepWalking,

  /// Closer: "N steps to go".
  stepsAhead,

  /// Farther: "you're moving away", then the way back.
  away,
}

/// Progress along the leg being walked (Phase C): how near the next stop
/// has been, and what the last update said. The stall check
/// ([stalled]) and the 25 s update ([update]) share it, and a new leg, a
/// fresh instruction or a floor change starts it again ([reset]).
class LegProgress {
  /// This much nearer the next stop counts as progress (see isStalled).
  static const stallProgressMeters = 3.0;

  double? _bestMeters;
  DateTime? _lastProgressAt;
  double? _updateMeters;
  int? _updateSteps;

  /// Starts afresh, [meters] from the next stop (null: the next update
  /// speaks regardless).
  void reset(double? meters) {
    _bestMeters = null;
    _lastProgressAt = null;
    _updateMeters = meters;
    _updateSteps = meters == null ? null : roundSteps(meters);
  }

  /// [meters] from the next stop now: true when there's been no real
  /// progress for a while ([isStalled]) and no [trustedHeading] to guide
  /// by. Then it counts as said, and the next stall is as long again.
  bool stalled(double meters, {required bool trustedHeading, DateTime? now}) {
    final at = now ?? clock.now();
    final best = _bestMeters;
    if (best == null || meters <= best - stallProgressMeters) {
      _bestMeters = meters;
      _lastProgressAt = at;
      return false;
    }
    if (trustedHeading ||
        !isStalled(lastProgressAt: _lastProgressAt, now: at)) {
      return false;
    }
    _lastProgressAt = at;
    return true;
  }

  /// The periodic update, [meters] from the next stop (see progressSince).
  /// It speaks after real progress, never the same step count twice.
  LegUpdate update(double meters) {
    switch (progressSince(lastMeters: _updateMeters, meters: meters)) {
      case Progress.same:
        return LegUpdate.keepWalking;
      case Progress.closer:
        _updateMeters = meters;
        final steps = roundSteps(meters);
        if (steps == _updateSteps) return LegUpdate.quiet;
        _updateSteps = steps;
        return LegUpdate.stepsAhead;
      case Progress.away:
        reset(meters);
        return LegUpdate.away;
    }
  }
}

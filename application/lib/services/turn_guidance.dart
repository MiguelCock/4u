import 'dart:math';

/// Something the navigation screen should say. Produced by [TurnGuidance]
/// from the compass heading vs the bearing to the next waypoint.
sealed class GuidanceCue {
  const GuidanceCue();
}

/// "Turn left/right about N degrees" (or "turn around" above 150).
class TurnCue extends GuidanceCue {
  /// Rounded to 15-degree steps, always positive.
  final int degrees;
  final bool right;

  const TurnCue({required this.degrees, required this.right});

  bool get turnAround => degrees > 150;

  factory TurnCue.from(double signedTurn) => TurnCue(
    degrees: roundTurnDegrees(signedTurn.abs()),
    right: signedTurn > 0,
  );
}

/// "You're facing the right way. Start walking forward, N meters."
class StartWalkingCue extends GuidanceCue {
  final int meters;

  const StartWalkingCue(this.meters);
}

/// Turn amounts are spoken in 15-degree steps (never "0"): users can't act
/// on finer precision, and the compass isn't that accurate anyway.
int roundTurnDegrees(double absDegrees) =>
    max(15, (absDegrees / 15).round() * 15);

/// Distances are spoken roughly: to the meter under 10m, then to 5m, then
/// to 10m - a GPS-derived distance jitters too much for more.
int roundMeters(double meters) {
  if (meters < 10) return max(1, meters.round());
  if (meters < 50) return (meters / 5).round() * 5;
  return (meters / 10).round() * 10;
}

/// Face-then-walk state machine toward one target at a time.
///
/// - **Orienting**: while the user faces more than [orientDegrees] away from
///   the target, say which way and how far to turn. Repeat when the needed
///   turn changes by more than [repeatChangeDegrees] (after at least
///   [repeatMinGap]), or every [repeatIdle] if nothing changes.
/// - Once within [alignedDegrees] for [alignedHold]: "start walking", and
///   switch to **walking**, which stays quiet...
/// - ...unless the user drifts more than [offCourseDegrees] off for
///   [offCourseHold]: back to orienting with a new turn instruction.
///
/// The gap between [alignedDegrees] and [orientDegrees] is hysteresis, so a
/// heading hovering around the edge doesn't flip-flop.
class TurnGuidance {
  static const alignedDegrees = 20.0;
  static const orientDegrees = 25.0;
  static const offCourseDegrees = 45.0;
  static const alignedHold = Duration(milliseconds: 1500);
  static const offCourseHold = Duration(seconds: 3);
  static const repeatMinGap = Duration(seconds: 4);
  static const repeatIdle = Duration(seconds: 10);
  static const repeatChangeDegrees = 20.0;

  bool _walking = false;
  DateTime? _alignedSince;
  DateTime? _offCourseSince;
  DateTime? _lastTurnAt;
  double? _lastTurn;

  bool get walking => _walking;

  /// Starts guiding toward a new target. Pass [announcedTurn] when the
  /// caller already spoke a turn for it (the "at this point, turn left..."
  /// waypoint sentence), so it isn't repeated straight away; pass
  /// [walking] when that sentence was "continue straight".
  void reset({
    required DateTime now,
    double? announcedTurn,
    bool walking = false,
  }) {
    _walking = walking;
    _alignedSince = null;
    _offCourseSince = null;
    _lastTurn = announcedTurn;
    _lastTurnAt = announcedTurn == null ? null : now;
  }

  /// [turn] is [signedTurn] from the current heading to the target's
  /// bearing; [metersToTarget] goes into the "start walking" sentence.
  GuidanceCue? update({
    required double turn,
    required double metersToTarget,
    required DateTime now,
  }) {
    final off = turn.abs();
    if (_walking) {
      if (off <= offCourseDegrees) {
        _offCourseSince = null;
        return null;
      }
      _offCourseSince ??= now;
      if (now.difference(_offCourseSince!) < offCourseHold) return null;
      _walking = false;
      _offCourseSince = null;
      return _turn(turn, now);
    }

    if (off <= alignedDegrees) {
      _alignedSince ??= now;
      if (now.difference(_alignedSince!) < alignedHold) return null;
      _walking = true;
      _alignedSince = null;
      _lastTurn = null;
      _lastTurnAt = null;
      return StartWalkingCue(roundMeters(metersToTarget));
    }
    _alignedSince = null;
    if (off < orientDegrees) return null;

    final lastTurn = _lastTurn;
    final lastAt = _lastTurnAt;
    if (lastTurn == null || lastAt == null) return _turn(turn, now);
    final since = now.difference(lastAt);
    final changed = (turn - lastTurn).abs() > repeatChangeDegrees;
    if ((changed && since >= repeatMinGap) || since >= repeatIdle) {
      return _turn(turn, now);
    }
    return null;
  }

  TurnCue _turn(double turn, DateTime now) {
    _lastTurn = turn;
    _lastTurnAt = now;
    return TurnCue.from(turn);
  }
}

/// Smooths compass readings (degrees, wrapping at 360) with an exponential
/// moving average on the unit circle, so a jittery sensor doesn't make the
/// turn instructions jump around - and 359 -> 1 averages to 0, not 180.
class HeadingSmoother {
  final double alpha;
  double? _x;
  double? _y;

  HeadingSmoother({this.alpha = 0.3});

  double? get value {
    final x = _x;
    final y = _y;
    if (x == null || y == null) return null;
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  double add(double degrees) {
    final radians = degrees * pi / 180;
    final x = cos(radians);
    final y = sin(radians);
    _x = _x == null ? x : _x! + alpha * (x - _x!);
    _y = _y == null ? y : _y! + alpha * (y - _y!);
    return value!;
  }
}

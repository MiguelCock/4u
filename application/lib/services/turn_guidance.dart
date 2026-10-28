import 'dart:math';

import 'geo_utils.dart';

/// Something the navigation screen should say. Produced by [TurnGuidance]
/// from the compass heading vs the bearing to the next waypoint.
sealed class GuidanceCue {
  const GuidanceCue();
}

/// How much to turn, in words: blind users in the first user test didn't
/// relate to degrees ("gira 75 grados") and turned about 90 degrees every
/// time anyway.
enum TurnKind {
  /// "Turn slightly left" (up to 60 degrees).
  slight,

  /// "Turn left" (60-150 degrees).
  normal,

  /// "Turn around" (over 150 degrees).
  around,
}

/// "Turn (slightly) left/right", or "turn around".
class TurnCue extends GuidanceCue {
  final TurnKind kind;
  final bool right;

  const TurnCue({required this.kind, required this.right});

  bool get turnAround => kind == TurnKind.around;

  factory TurnCue.from(double signedTurn) {
    final off = signedTurn.abs();
    return TurnCue(
      kind: off > 150
          ? TurnKind.around
          : off > 60
          ? TurnKind.normal
          : TurnKind.slight,
      right: signedTurn > 0,
    );
  }
}

/// "Good. Go straight, about N steps."
class StartWalkingCue extends GuidanceCue {
  final int steps;

  const StartWalkingCue(this.steps);
}

/// Average step length (meters) used to speak distances as steps, which the
/// user test asked for instead of meters.
const double stepLengthMeters = 0.7;

/// [meters] as a rough number of steps: exact under 10, then to 5, then to
/// 10 - a GPS-derived distance jitters too much for more.
int roundSteps(double meters) {
  final steps = meters / stepLengthMeters;
  if (steps < 10) return max(1, steps.round());
  if (steps < 50) return (steps / 5).round() * 5;
  return (steps / 10).round() * 10;
}

/// Face-then-walk state machine toward one target at a time.
///
/// - **Orienting** (only with a reliable heading, see HeadingTracker): while
///   the user faces more than [orientDegrees] away from the target, say
///   which way to turn. Repeat when the needed turn changes by more than
///   [repeatChangeDegrees] (after at least [repeatMinGap]), or every
///   [repeatIdle] if nothing changes - never while the user is turning.
/// - Once within [alignedDegrees] for [alignedHold]: "start walking", and
///   switch to **walking**, which stays quiet...
/// - ...unless the user drifts more than [offCourseDegrees] off for
///   [offCourseHold]: one correction, then quiet again for at least
///   [correctionGap]. No loop: a user test got a "turn right" every ~10 s
///   for minutes from a compass that was ~85 degrees off.
/// - Without a reliable heading nothing is said at all: the screen speaks
///   the corners from the route itself.
///
/// The gap between [alignedDegrees] and [orientDegrees] is hysteresis, so a
/// heading hovering around the edge doesn't flip-flop.
class TurnGuidance {
  // Widened after a field test: with a compass that sways by ±15° while
  // walking, 20/25 turned straight walking into "turn 30 degrees" cues.
  static const alignedDegrees = 25.0;
  static const orientDegrees = 35.0;
  static const offCourseDegrees = 50.0;
  static const alignedHold = Duration(milliseconds: 1500);
  static const offCourseHold = Duration(seconds: 5);
  static const correctionGap = Duration(seconds: 10);
  static const repeatMinGap = Duration(seconds: 4);
  static const repeatIdle = Duration(seconds: 10);
  static const repeatChangeDegrees = 20.0;

  /// A needed turn that moved more than this within [rotatingWindow] means
  /// the user is turning right now: no repeat until they stop. A field test
  /// got "turn left about 60 degrees" halfway through a 90-degree turn.
  static const rotatingDegrees = 10.0;
  static const rotatingWindow = Duration(seconds: 1);
  final List<({DateTime at, double turn})> _recentTurns = [];

  /// Recent |turn| samples while walking: off course is judged on their
  /// median, so one swing of the compass doesn't count (and one aligned
  /// sample doesn't reset a real drift).
  static const _offCourseSamples = 5;
  final List<double> _recentOff = [];

  bool _walking = false;
  DateTime? _alignedSince;
  DateTime? _offCourseSince;
  DateTime? _lastCorrectionAt;
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
    _recentOff.clear();
    _alignedSince = null;
    _offCourseSince = null;
    _lastCorrectionAt = null;
    _lastTurn = announcedTurn;
    _lastTurnAt = announcedTurn == null ? null : now;
    _recentTurns.clear();
  }

  /// [turn] is [signedTurn] from the current heading to the target's
  /// bearing; [metersToTarget] goes into the "start walking" sentence.
  /// [reliable]: whether that heading can be trusted (HeadingTracker); if
  /// not, nothing is said.
  GuidanceCue? update({
    required double turn,
    required double metersToTarget,
    required DateTime now,
    bool reliable = true,
  }) {
    if (!reliable) {
      _offCourseSince = null;
      _alignedSince = null;
      _recentOff.clear();
      return null;
    }
    final off = turn.abs();
    _recentTurns
      ..removeWhere((t) => now.difference(t.at) > rotatingWindow)
      ..add((at: now, turn: turn));
    if (_walking) {
      _recentOff.add(off);
      if (_recentOff.length > _offCourseSamples) _recentOff.removeAt(0);
      if (_median(_recentOff) <= offCourseDegrees) {
        _offCourseSince = null;
        return null;
      }
      _offCourseSince ??= now;
      if (now.difference(_offCourseSince!) < offCourseHold) return null;
      final lastCorrection = _lastCorrectionAt;
      if (lastCorrection != null &&
          now.difference(lastCorrection) < correctionGap) {
        return null;
      }
      _offCourseSince = null;
      _recentOff.clear();
      _lastCorrectionAt = now;
      return TurnCue.from(turn);
    }

    if (off <= alignedDegrees) {
      _alignedSince ??= now;
      if (now.difference(_alignedSince!) < alignedHold) return null;
      _walking = true;
      _alignedSince = null;
      _lastTurn = null;
      _lastTurnAt = null;
      return StartWalkingCue(roundSteps(metersToTarget));
    }
    _alignedSince = null;
    if (off < orientDegrees) return null;

    final lastTurn = _lastTurn;
    final lastAt = _lastTurnAt;
    if (lastTurn == null || lastAt == null) return _turn(turn, now);
    if (_rotating(turn)) return null;
    final since = now.difference(lastAt);
    final changed = (turn - lastTurn).abs() > repeatChangeDegrees;
    if ((changed && since >= repeatMinGap) || since >= repeatIdle) {
      return _turn(turn, now);
    }
    return null;
  }

  bool _rotating(double turn) =>
      _recentTurns.any((t) => signedTurn(t.turn, turn).abs() > rotatingDegrees);

  static double _median(List<double> values) {
    final sorted = List.of(values)..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  TurnCue _turn(double turn, DateTime now) {
    _lastTurn = turn;
    _lastTurnAt = now;
    return TurnCue.from(turn);
  }
}

/// Smooths compass readings (degrees, wrapping at 360) on the unit circle,
/// so 359 -> 1 averages to 0, not 180. Smoothing is by *time*
/// ([timeConstant]), not per reading: the plugin sends a reading every
/// ~32 ms, so a per-reading factor of 0.3 averaged over just ~0.1 s and
/// walking sway went straight into the turn instructions.
class HeadingSmoother {
  final Duration timeConstant;
  double? _x;
  double? _y;
  DateTime? _last;

  HeadingSmoother({this.timeConstant = const Duration(seconds: 1)});

  double? get value {
    final x = _x;
    final y = _y;
    if (x == null || y == null) return null;
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  double add(double degrees, {DateTime? at}) {
    final now = at ?? DateTime.now();
    final radians = degrees * pi / 180;
    final x = cos(radians);
    final y = sin(radians);
    final last = _last;
    if (_x == null || last == null) {
      _x = x;
      _y = y;
    } else {
      final dt = now.difference(last).inMicroseconds / 1e6;
      final tau = timeConstant.inMicroseconds / 1e6;
      final alpha = tau <= 0 ? 1.0 : 1 - exp(-max(dt, 0) / tau);
      _x = _x! + alpha * (x - _x!);
      _y = _y! + alpha * (y - _y!);
    }
    _last = now;
    return value!;
  }
}

/// Compass headings are magnetic; route bearings are true north. The
/// difference is the local magnetic declination (east positive): about
/// -7.5° in Medellín. Set MAGNETIC_DECLINATION in .env for another campus
/// (NOAA's declination calculator gives the value).
double trueHeading(double magnetic, double declination) =>
    (magnetic + declination + 360) % 360;

/// How close (meters) to the destination counts as arrived: twice the GPS
/// accuracy, between [minMeters] and [maxMeters], and never more than half
/// the last leg.
///
/// A fixed 15 m ended a field-test trip at the last corner: the final leg
/// was only 13 m long, so reaching the corner was already "arrived" and
/// that leg was never guided. Good GPS (3 m) now means arriving within
/// ~6 m.
double arrivalRadius({
  required double gpsAccuracy,
  double? lastLegMeters,
  double minMeters = 5,
  double maxMeters = 15,
}) {
  var radius = (2 * gpsAccuracy).clamp(minMeters, maxMeters).toDouble();
  if (lastLegMeters != null) {
    radius = min(radius, max(minMeters, lastLegMeters / 2));
  }
  return radius;
}

/// Where the user is relative to the corner ending the leg they walk.
enum CornerProgress { approaching, warn, reached }

/// The corner counts as reached within [reachedMeters] of it, or within
/// that of its end along the leg (while no more than [maxCrossTrackMeters]
/// to the side), or once the user has already turned onto the next leg
/// near it (heading within [turnedOntoDegrees] of the next leg and more
/// than [leftLegDegrees] off the current one). [warnMeters] before it the
/// screen gives a heads-up. A field test with an 8 m reach radius spoke
/// every turn 5-8 s before the corner, once the position was good to ~1 m.
CornerProgress cornerProgress({
  required double metersToCorner,
  required double alongRemaining,
  required double crossTrack,
  double? heading,
  double? legBearing,
  double? nextLegBearing,
  double reachedMeters = 3,
  double warnMeters = 8,
  double maxCrossTrackMeters = 15,
  double turnedOntoDegrees = 30,
  double leftLegDegrees = 45,
}) {
  final onLeg = crossTrack.abs() <= maxCrossTrackMeters;
  if (metersToCorner <= reachedMeters ||
      (onLeg && alongRemaining <= reachedMeters)) {
    return CornerProgress.reached;
  }
  final near =
      metersToCorner <= warnMeters || (onLeg && alongRemaining <= warnMeters);
  if (near &&
      heading != null &&
      legBearing != null &&
      nextLegBearing != null &&
      signedTurn(heading, nextLegBearing).abs() <= turnedOntoDegrees &&
      signedTurn(heading, legBearing).abs() > leftLegDegrees) {
    return CornerProgress.reached;
  }
  return near ? CornerProgress.warn : CornerProgress.approaching;
}

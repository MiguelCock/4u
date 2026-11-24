/// Which side the user is drifting to, off the line of the leg (B4, #180).
enum DriftSide { left, right }

/// Watches the sideways distance from the leg being walked, and says when
/// the user has drifted off to one side for a while (B4, #180). Testers
/// faced the right way but slid sideways, and nothing was said until they
/// were well off the path. The 2026-11-14 test asked for the side.
///
/// GPS wobbles by several metres, so a drift has to last [sustain] beyond
/// [driftMeters] before it counts, and it's said at most every [cooldown].
/// It can also tell earlier, from the movement (B8, #300): facing the leg
/// but walking [courseOffDeg] off it, away from the line, [earlyMeters] out,
/// for [earlySustain]. Facing right while sliding sideways is exactly what
/// testers did, and the GPS course shows it before the offset reaches 8 m.
class DriftWatch {
  DriftWatch({
    this.driftMeters = 8,
    this.onPathMeters = 5,
    this.sustain = const Duration(seconds: 5),
    this.cooldown = const Duration(seconds: 30),
    this.earlyMeters = 4,
    this.courseOffDeg = 25,
    this.earlySustain = const Duration(seconds: 3),
  });

  /// Beyond this, sideways, the user is drifting. Under guidanceBearing's
  /// 10 m tolerance, which asks for no turn at all.
  final double driftMeters;

  /// Within this, the user is on the path ("vas bien").
  final double onPathMeters;
  final Duration sustain;
  final Duration cooldown;

  /// The early trigger: at least this far out...
  final double earlyMeters;

  /// ...with the walking direction at least this far off the leg, away
  /// from it...
  final double courseOffDeg;

  /// ...for this long.
  final Duration earlySustain;

  DateTime? _driftSince;
  DateTime? _earlySince;
  DriftSide? _earlySide;
  DriftSide? _side;
  DateTime? _lastSaidAt;

  /// The last sideways distance seen (positive: right of the leg).
  double? crossTrack;

  /// Whether the last distance seen was on the path.
  bool get onPath => crossTrack != null && crossTrack!.abs() <= onPathMeters;

  /// A new leg, or nothing to compare against: start over.
  void reset() {
    _driftSince = null;
    _side = null;
    _earlySince = null;
    _earlySide = null;
    crossTrack = null;
  }

  /// [crossTrack] metres from the leg's line (positive: to its right) at
  /// [now]. [courseOff] is the steady GPS course's turn from the leg's
  /// bearing (positive: to its right), when there is one, and
  /// [facingLeg] whether a trusted heading faces the leg. Returns the side
  /// to announce, or null.
  DriftSide? update(
    double crossTrack,
    DateTime now, {
    double? courseOff,
    bool facingLeg = false,
  }) {
    this.crossTrack = crossTrack;
    final side = crossTrack > 0 ? DriftSide.right : DriftSide.left;
    final early = _early(crossTrack, side, now, courseOff, facingLeg);
    if (crossTrack.abs() <= driftMeters) {
      _driftSince = null;
      _side = null;
      return early ? _say(side, now) : null;
    }
    if (side != _side) {
      _side = side;
      _driftSince = now;
      return early ? _say(side, now) : null;
    }
    if (!early && now.difference(_driftSince!) < sustain) return null;
    return _say(side, now);
  }

  /// Whether the movement shows a drift: facing the leg, walking off it,
  /// away from the line, far enough out, for [earlySustain].
  bool _early(
    double crossTrack,
    DriftSide side,
    DateTime now,
    double? courseOff,
    bool facingLeg,
  ) {
    final away =
        courseOff != null &&
        courseOff.abs() >= courseOffDeg &&
        (courseOff > 0) == (crossTrack > 0);
    if (!facingLeg || !away || crossTrack.abs() < earlyMeters) {
      _earlySince = null;
      _earlySide = null;
      return false;
    }
    if (side != _earlySide) {
      _earlySide = side;
      _earlySince = now;
    }
    return now.difference(_earlySince!) >= earlySustain;
  }

  DriftSide? _say(DriftSide side, DateTime now) {
    final last = _lastSaidAt;
    if (last != null && now.difference(last) < cooldown) return null;
    _lastSaidAt = now;
    return side;
  }
}

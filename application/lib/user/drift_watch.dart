/// Which side the user is drifting to, off the line of the leg (B4, #180).
enum DriftSide { left, right }

/// Watches the sideways distance from the leg being walked, and says when
/// the user has drifted off to one side for a while (B4, #180). Testers
/// faced the right way but slid sideways, and nothing was said until they
/// were well off the path. The 2026-11-14 test asked for the side.
///
/// GPS wobbles by several metres, so a drift has to last [sustain] beyond
/// [driftMeters] before it counts, and it's said at most every [cooldown].
/// The thresholds are first guesses, to be tuned on replays (B8, #300).
class DriftWatch {
  DriftWatch({
    this.driftMeters = 8,
    this.onPathMeters = 5,
    this.sustain = const Duration(seconds: 5),
    this.cooldown = const Duration(seconds: 30),
  });

  /// Beyond this, sideways, the user is drifting. Under guidanceBearing's
  /// 10 m tolerance, which asks for no turn at all.
  final double driftMeters;

  /// Within this, the user is on the path ("vas bien").
  final double onPathMeters;
  final Duration sustain;
  final Duration cooldown;

  DateTime? _driftSince;
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
    crossTrack = null;
  }

  /// [crossTrack] metres from the leg's line (positive: to its right) at
  /// [now]. Returns the side to announce, or null.
  DriftSide? update(double crossTrack, DateTime now) {
    this.crossTrack = crossTrack;
    if (crossTrack.abs() <= driftMeters) {
      _driftSince = null;
      _side = null;
      return null;
    }
    final side = crossTrack > 0 ? DriftSide.right : DriftSide.left;
    if (side != _side) {
      _side = side;
      _driftSince = now;
      return null;
    }
    if (now.difference(_driftSince!) < sustain) return null;
    final last = _lastSaidAt;
    if (last != null && now.difference(last) < cooldown) return null;
    _lastSaidAt = now;
    return side;
  }
}

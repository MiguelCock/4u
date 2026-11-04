import 'dart:collection';

/// Hears a floor change from the barometer: GPS can't tell floors apart, and
/// each floor is about 0.36 hPa at Cali's altitude (3.5 m at ~0.103 hPa/m).
///
/// A trip feeds every reading to [add]. [start] takes the mean of the last
/// [baselineWindow] as the floor the user is leaving; [reached] turns true once
/// the mean of the last [smoothWindow] has moved the right way by
/// [hPaPerFloor] per floor and stayed there for [hold]. So a gust or a door
/// (brief), a slow change in the weather (far below this over a few minutes)
/// and going the wrong way don't count.
///
/// First guesses, to tune on campus: see `docs/TUNING.md` §9.
class FloorChangeDetector {
  static const hPaPerFloor = 0.28;
  static const baselineWindow = Duration(seconds: 5);
  static const smoothWindow = Duration(seconds: 2);
  static const hold = Duration(seconds: 3);

  final Queue<({DateTime at, double hPa})> _samples = Queue();

  double? _baseline;
  int _floors = 0;
  DateTime? _heldSince;
  bool _reached = false;

  bool get reached => _reached;

  /// The latest reading, null before the first.
  double? get pressure => _samples.isEmpty ? null : _samples.last.hPa;

  /// How far the smoothed pressure has moved from the baseline; null when not
  /// waiting for a floor change. Negative is upward.
  double? get delta {
    final baseline = _baseline;
    if (baseline == null || _samples.isEmpty) return null;
    return _mean(_samples.last.at, smoothWindow) - baseline;
  }

  /// Starts waiting for a change of [floors] floors (negative: going down).
  /// With no recent reading, the first one to come is the baseline.
  void start(int floors, {required DateTime now}) {
    _floors = floors;
    _heldSince = null;
    _reached = false;
    final recent = _samples.any((s) => now.difference(s.at) <= baselineWindow);
    _baseline = recent ? _mean(now, baselineWindow) : null;
  }

  void stop() {
    _floors = 0;
    _baseline = null;
    _heldSince = null;
    _reached = false;
  }

  void add(double hPa, DateTime at) {
    _samples.addLast((at: at, hPa: hPa));
    while (at.difference(_samples.first.at) > baselineWindow) {
      _samples.removeFirst();
    }
    if (_floors == 0 || _reached) return;
    _baseline ??= hPa;
    // Going up, pressure falls.
    final moved = _floors > 0 ? -delta! : delta!;
    if (moved < _floors.abs() * hPaPerFloor) {
      _heldSince = null;
      return;
    }
    _heldSince ??= at;
    if (at.difference(_heldSince!) >= hold) _reached = true;
  }

  double _mean(DateTime now, Duration window) {
    var sum = 0.0;
    var count = 0;
    for (final s in _samples) {
      if (now.difference(s.at) <= window) {
        sum += s.hPa;
        count++;
      }
    }
    return count == 0 ? _samples.last.hPa : sum / count;
  }
}

/// Pieces of the admin test walk ("Test as user") that measure the GPS
/// correction: the admin walks the planned route exactly and taps a
/// checkpoint at the start, at every corner and at the destination, so
/// the true position is known for every tick (steady pace between taps,
/// see backend-positioning/scripts/replay.py).
library;

/// The checkpoints of one route, in order: 0 is the start, the last is
/// the destination, the ones between are the route's corners.
class CheckpointSequence {
  CheckpointSequence(this.count);

  /// How many checkpoints the route has (start + corners + destination).
  final int count;
  int _marked = 0;

  /// The index the next tap records, or null once all are marked.
  int? get next => _marked < count ? _marked : null;

  bool get isDestinationNext => count > 0 && _marked == count - 1;

  bool get done => _marked >= count;

  /// Records the next checkpoint and returns its index, or null if every
  /// one is already marked.
  int? mark() {
    final index = next;
    if (index != null) _marked++;
    return index;
  }

  /// Takes back the last mark (a tap at the wrong spot). Returns the index
  /// taken back, or null if there's none.
  int? undo() {
    if (_marked == 0) return null;
    _marked--;
    return _marked;
  }
}

/// How long to wait before the next correction tick so ticks start every
/// [period] - not [period] after the previous one finished, which made a
/// 1 s loop run every ~3.7 s in a field test.
Duration nextTickDelay(
  Duration elapsed, {
  Duration period = const Duration(seconds: 1),
}) => elapsed >= period ? Duration.zero : period - elapsed;

/// How long no photos are sent after the server answers `server_busy`. Well
/// inside the 20 s after which a correction counts as stale, and guidance has
/// its own timer, so it isn't affected.
const photoPauseWhenBusy = Duration(seconds: 5);

/// How often ticks run during that pause: about the usual rhythm of a tick with
/// a photo. At the normal 1 s floor, the logs alone would triple.
const pausedTickPeriod = Duration(seconds: 3);

/// Whether this tick should skip its photo.
bool photoPaused(DateTime now, DateTime? pausedUntil) =>
    pausedUntil != null && now.isBefore(pausedUntil);

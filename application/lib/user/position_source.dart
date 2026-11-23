import 'package:clock/clock.dart';
import 'package:latlong2/latlong.dart';

import '../services/geo_utils.dart';

/// Where the trip thinks the user is (Phase C): the live GPS fix moved by
/// the latest camera correction while it's fresh, else raw GPS, blending
/// between the two instead of jumping.
class PositionSource {
  PositionSource({
    this.freshFor = const Duration(seconds: 20),
    this.blendOver = const Duration(seconds: 2),
  });

  /// A correction's offset from raw GPS is applied to the live fix for this
  /// long, then dropped in favour of raw GPS (the camera loop has stalled).
  /// The offset is the GPS's own slowly changing error (backend-positioning's
  /// bias, tau 120 s), so it holds well past the next tick. Showing the
  /// corrected position itself put it 5-11 s behind the user in a field
  /// test: a tick's answer arrives ~5 s after its photo.
  final Duration freshFor;

  /// When the correction goes stale, guidance moves from the last corrected
  /// position to raw GPS over this long.
  final Duration blendOver;

  /// The last correction as the server gave it, and its error estimate.
  LatLng? corrected;
  double? correctionError;
  DateTime? correctedAt;

  /// The last correction minus the raw fix it corrected, metres east/north.
  ({double x, double y})? _offset;

  DateTime? _staleSince;
  LatLng? _staleFrom;
  bool _usedCorrected = false;

  /// Whether the last [current] was the corrected position, for the logs.
  bool get usedCorrected => _usedCorrected;

  /// There is a correction whose offset can be applied.
  bool get hasCorrection => _offset != null;

  /// The server corrected [raw] to [to], give or take [error] metres.
  void correct(LatLng raw, LatLng to, double error) {
    corrected = to;
    correctionError = error;
    correctedAt = clock.now();
    _offset = offsetMeters(raw, to);
  }

  /// [raw] moved by the latest correction, while it's fresh; null
  /// otherwise.
  LatLng? live(LatLng? raw) {
    final offset = _offset;
    final at = correctedAt;
    if (offset == null ||
        at == null ||
        raw == null ||
        clock.now().difference(at) >= freshFor) {
      return null;
    }
    return applyOffset(raw, offset.x, offset.y);
  }

  /// Where guidance thinks the user is, from the live fix [raw]: [live]
  /// while fresh, else raw GPS, reached over [blendOver] from the last
  /// corrected position. It remembers which it used, and since when the
  /// correction is stale.
  LatLng? current(LatLng? raw) {
    final corrected = live(raw);
    if (corrected != null) {
      _usedCorrected = true;
      _staleSince = null;
      _staleFrom = corrected;
      return corrected;
    }
    _usedCorrected = false;
    if (raw == null) return null;
    final from = _staleFrom;
    if (from != null) {
      final since = _staleSince ??= clock.now();
      final f =
          (clock.now().difference(since).inMilliseconds /
                  blendOver.inMilliseconds)
              .clamp(0.0, 1.0);
      if (f < 1) {
        return LatLng(
          from.latitude + (raw.latitude - from.latitude) * f,
          from.longitude + (raw.longitude - from.longitude) * f,
        );
      }
    }
    return raw;
  }
}

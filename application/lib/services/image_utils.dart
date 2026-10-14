import 'dart:math' show sqrt;
import 'dart:typed_data' show Uint8List;

import 'package:image/image.dart' as img;

/// Mean luma (0-255) below this reads as "nothing to see" - a lens
/// cap/finger/pocket produces a flat, near-black frame.
const double kCameraBlockedMeanLumaThreshold = 15.0;

/// A real scene, even a dim one, has texture (edges, shadows, varying
/// surfaces) - a covered lens doesn't. Standard deviation of sampled luma
/// below this, even if the mean itself isn't very low (e.g. a lens pressed
/// against a bright white surface), also reads as blocked.
const double kCameraBlockedStdDevThreshold = 8.0;

/// Whether [jpegBytes] looks like a blocked/covered camera - a flat,
/// near-uniform frame (very dark, or very bright with no texture) rather
/// than a real scene. Decoded at a small, bounded size (not full
/// resolution), since `navigation_screen.dart` calls this on every ~1s
/// correction tick and a full decode would add meaningful latency on top
/// of #122's existing concerns. A v1 heuristic to benchmark on-device, not
/// a polished solution. Returns `false` (never blocks navigation over a
/// decode failure) if [jpegBytes] can't be decoded at all.
bool isFrameBlocked(
  Uint8List jpegBytes, {
  double meanLumaThreshold = kCameraBlockedMeanLumaThreshold,
  double stdDevThreshold = kCameraBlockedStdDevThreshold,
}) {
  final decoded = img.decodeImage(jpegBytes);
  if (decoded == null) return false;
  final small = img.copyResize(decoded, width: 32, height: 32);
  final lumas = [for (final pixel in small) img.getLuminance(pixel)];
  final mean = lumas.reduce((a, b) => a + b) / lumas.length;
  final variance =
      lumas.map((l) => (l - mean) * (l - mean)).reduce((a, b) => a + b) /
      lumas.length;
  return mean < meanLumaThreshold || sqrt(variance) < stdDevThreshold;
}

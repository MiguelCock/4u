import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

/// How strong a buzz is: [short] marks listening and instructions, [long]
/// is "start walking" and arrival.
enum Buzz { short, long }

/// Milliseconds per kind of buzz.
const Map<Buzz, int> buzzMillis = {Buzz.short: 60, Buzz.long: 250};

/// A vibration people feel. `HapticFeedback` follows Android's "touch
/// vibration" setting, which is often off, and a tester felt nothing. This
/// drives the vibrator itself, and falls back to `HapticFeedback` where
/// there's none (or on web, or in tests).
Future<void> buzz(Buzz kind, {Future<bool> Function()? hasVibrator}) async {
  try {
    if (!kIsWeb && await (hasVibrator ?? Vibration.hasVibrator)()) {
      await Vibration.vibrate(duration: buzzMillis[kind]!);
      return;
    }
  } catch (_) {
    // No plugin here: the fallback below.
  }
  await (kind == Buzz.long
      ? HapticFeedback.heavyImpact()
      : HapticFeedback.mediumImpact());
}

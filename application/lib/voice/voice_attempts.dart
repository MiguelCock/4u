import 'package:clock/clock.dart';

/// One thing the recognizer heard: its words and confidence (0-1, or -1
/// when the recognizer gives none).
typedef Heard = ({String words, double confidence});

/// The home screen's recognition attempts, for #262 (noise and other
/// voices): what was heard, the recognizer's alternates with their
/// confidence, the loudest sound during the listen, and how it ended. The
/// home screen has no session to log to, so they wait here and the next
/// trip's first log takes them ([drain]).
class VoiceAttempts {
  VoiceAttempts._();
  static final instance = VoiceAttempts._();

  /// Kept, at most: older ones are dropped first.
  static const keep = 30;

  final List<Map<String, dynamic>> _attempts = [];

  void add({
    required List<Heard> heard,
    required double? soundPeak,
    required String outcome,
    String? used,
  }) {
    _attempts.add({
      'at': clock.now().toUtc().toIso8601String(),
      'alternates': [
        for (final h in heard) {'words': h.words, 'confidence': h.confidence},
      ],
      'sound_peak': soundPeak,
      'outcome': outcome,
      'used': ?used,
    });
    if (_attempts.length > keep) _attempts.removeAt(0);
  }

  /// Everything kept, emptied.
  List<Map<String, dynamic>> drain() {
    final out = List<Map<String, dynamic>>.of(_attempts);
    _attempts.clear();
    return out;
  }
}

/// The words to act on (#262): [heard]'s first if it means something to
/// [resolve], else the first alternate that does, in confidence order. A
/// neighbour's voice or the noise often wins the top spot while what the
/// user said is second. Null when none does.
({String words, T result})? bestHeard<T>(
  List<Heard> heard,
  T? Function(String words) resolve,
) {
  if (heard.isEmpty) return null;
  final first = resolve(heard.first.words);
  if (first != null) return (words: heard.first.words, result: first);
  final rest = heard.skip(1).toList()
    ..sort((a, b) => b.confidence.compareTo(a.confidence));
  for (final h in rest) {
    final r = resolve(h.words);
    if (r != null) return (words: h.words, result: r);
  }
  return null;
}

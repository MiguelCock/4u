import 'package:eyes4u/voice/voice_attempts.dart';
import 'package:flutter_test/flutter_test.dart';

String? _cafe(String words) => words.contains('cafetería') ? 'C' : null;

void main() {
  group('bestHeard (#262)', () {
    test('the top guess, when it means something', () {
      final best = bestHeard([
        (words: 'la cafetería', confidence: 0.9),
        (words: 'la cafetera', confidence: 0.4),
      ], _cafe);
      expect(best, (words: 'la cafetería', result: 'C'));
    });

    test('else the most confident alternate that does', () {
      final best = bestHeard([
        (words: 'vamos ya Pedro', confidence: 0.8),
        (words: 'la cafetería sur', confidence: 0.3),
        (words: 'a la cafetería', confidence: 0.6),
      ], _cafe);
      expect(best?.words, 'a la cafetería');
    });

    test('nothing that means anything, or nothing heard', () {
      expect(bestHeard([(words: 'ruido', confidence: 0.9)], _cafe), isNull);
      expect(bestHeard(<Heard>[], _cafe), isNull);
    });
  });

  test('attempts are kept, at most 30, and drained once', () {
    final log = VoiceAttempts.instance..drain();
    for (var i = 0; i < 35; i++) {
      log.add(
        heard: [(words: 'w$i', confidence: 0.5)],
        soundPeak: 7.5,
        outcome: 'no_match',
      );
    }
    final attempts = log.drain();
    expect(attempts, hasLength(VoiceAttempts.keep));
    expect((attempts.first['alternates'] as List).first['words'], 'w5');
    expect(attempts.first['sound_peak'], 7.5);
    expect(log.drain(), isEmpty);
  });
}

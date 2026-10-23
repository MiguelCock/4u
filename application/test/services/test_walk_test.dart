import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/test_walk.dart';

void main() {
  group('CheckpointSequence', () {
    test('marks start, corners and destination in order', () {
      final checkpoints = CheckpointSequence(5);
      expect(checkpoints.next, 0);
      expect([for (var i = 0; i < 4; i++) checkpoints.mark()], [0, 1, 2, 3]);
      expect(checkpoints.isDestinationNext, isTrue);
      expect(checkpoints.mark(), 4);
      expect(checkpoints.done, isTrue);
      expect(checkpoints.next, isNull);
      expect(checkpoints.mark(), isNull);
    });

    test('undo takes back the last mark only', () {
      final checkpoints = CheckpointSequence(3)
        ..mark()
        ..mark();
      expect(checkpoints.undo(), 1);
      expect(checkpoints.next, 1);
      expect(checkpoints.undo(), 0);
      expect(checkpoints.undo(), isNull);
    });
  });

  group('nextTickDelay', () {
    test('ticks start every second, counting the tick itself', () {
      expect(
        nextTickDelay(const Duration(milliseconds: 300)),
        const Duration(milliseconds: 700),
      );
    });

    test('a slow tick is followed straight away', () {
      expect(nextTickDelay(const Duration(seconds: 3)), Duration.zero);
    });
  });
}

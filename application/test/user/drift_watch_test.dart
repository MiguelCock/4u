import 'package:eyes4u/user/drift_watch.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime(2026, 11, 17, 10);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

void main() {
  test('a drift lasting long enough is said, with its side', () {
    final drift = DriftWatch();
    expect(drift.update(-10, _at(0)), isNull);
    expect(drift.update(-11, _at(3)), isNull, reason: 'not long enough');
    expect(drift.update(-12, _at(5)), DriftSide.left);
    final right = DriftWatch();
    right.update(9, _at(0));
    expect(right.update(9, _at(6)), DriftSide.right);
  });

  test('a GPS wobble back onto the line starts over', () {
    final drift = DriftWatch();
    drift.update(10, _at(0));
    drift.update(2, _at(3));
    drift.update(10, _at(4));
    expect(drift.update(10, _at(8)), isNull);
    expect(drift.update(10, _at(9)), DriftSide.right);
  });

  test('switching sides starts over', () {
    final drift = DriftWatch();
    drift.update(10, _at(0));
    expect(drift.update(-10, _at(6)), isNull);
    expect(drift.update(-10, _at(11)), DriftSide.left);
  });

  test('said at most once per cooldown, however long it lasts', () {
    final drift = DriftWatch();
    drift.update(10, _at(0));
    expect(drift.update(10, _at(5)), DriftSide.right);
    for (var s = 6; s < 35; s++) {
      expect(drift.update(10, _at(s)), isNull);
    }
    expect(drift.update(10, _at(35)), DriftSide.right);
  });

  test('on the path within 5 m, not beyond', () {
    final drift = DriftWatch();
    expect(drift.onPath, isFalse, reason: 'nothing seen yet');
    drift.update(-4, _at(0));
    expect(drift.onPath, isTrue);
    drift.update(6, _at(1));
    expect(drift.onPath, isFalse);
    drift.reset();
    expect(drift.onPath, isFalse);
  });

  group('from the movement (B8, #300)', () {
    test('facing the leg but walking off it is said early, under 8 m', () {
      final drift = DriftWatch();
      for (var t = 0; t < 3; t++) {
        expect(
          drift.update(4.5 + t, _at(t), courseOff: 35, facingLeg: true),
          isNull,
        );
      }
      expect(
        drift.update(7, _at(3), courseOff: 35, facingLeg: true),
        DriftSide.right,
      );
    });

    test('not without a trusted heading facing the leg', () {
      final drift = DriftWatch();
      for (var t = 0; t <= 4; t++) {
        expect(drift.update(6, _at(t), courseOff: 35), isNull);
      }
    });

    test('not when walking back towards the line', () {
      final drift = DriftWatch();
      for (var t = 0; t <= 4; t++) {
        expect(
          drift.update(6, _at(t), courseOff: -35, facingLeg: true),
          isNull,
          reason: 'right of the line, heading left: coming back',
        );
      }
    });

    test('not for a small course difference or close to the line', () {
      final small = DriftWatch();
      final close = DriftWatch();
      for (var t = 0; t <= 4; t++) {
        expect(small.update(6, _at(t), courseOff: 15, facingLeg: true), isNull);
        expect(close.update(3, _at(t), courseOff: 40, facingLeg: true), isNull);
      }
    });

    test('the cooldown holds across both triggers', () {
      final drift = DriftWatch();
      for (var t = 0; t <= 3; t++) {
        drift.update(5, _at(t), courseOff: 35, facingLeg: true);
      }
      for (var t = 4; t <= 20; t++) {
        expect(drift.update(12, _at(t)), isNull);
      }
    });
  });
}

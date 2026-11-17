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
}

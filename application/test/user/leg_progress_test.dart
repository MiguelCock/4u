import 'package:eyes4u/user/leg_progress.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime(2026, 11, 15, 10);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

void main() {
  group('stalled', () {
    test('after 20 s without 3 m of progress, then again 20 s later', () {
      final leg = LegProgress()..reset(30);
      expect(leg.stalled(30, trustedHeading: false, now: _at(0)), isFalse);
      expect(leg.stalled(28, trustedHeading: false, now: _at(19)), isFalse);
      expect(leg.stalled(28, trustedHeading: false, now: _at(20)), isTrue);
      expect(leg.stalled(28, trustedHeading: false, now: _at(30)), isFalse);
      expect(leg.stalled(28, trustedHeading: false, now: _at(40)), isTrue);
    });

    test('3 m nearer is progress, and the wait starts again', () {
      final leg = LegProgress()..reset(30);
      leg.stalled(30, trustedHeading: false, now: _at(0));
      expect(leg.stalled(27, trustedHeading: false, now: _at(15)), isFalse);
      expect(leg.stalled(27, trustedHeading: false, now: _at(34)), isFalse);
      expect(leg.stalled(27, trustedHeading: false, now: _at(35)), isTrue);
    });

    test('never with a trusted heading: turn guidance speaks then', () {
      final leg = LegProgress()..reset(30);
      leg.stalled(30, trustedHeading: true, now: _at(0));
      expect(leg.stalled(30, trustedHeading: true, now: _at(60)), isFalse);
    });

    test('a reset starts the count again', () {
      final leg = LegProgress()..reset(30);
      leg.stalled(30, trustedHeading: false, now: _at(0));
      leg.reset(30);
      expect(leg.stalled(30, trustedHeading: false, now: _at(20)), isFalse);
      expect(leg.stalled(30, trustedHeading: false, now: _at(39)), isFalse);
      expect(leg.stalled(30, trustedHeading: false, now: _at(40)), isTrue);
    });
  });

  group('the periodic update', () {
    test('closer: says the steps, never the same count twice', () {
      final leg = LegProgress()..reset(40);
      expect(leg.update(30), LegUpdate.stepsAhead);
      expect(leg.update(26), LegUpdate.stepsAhead);
      expect(leg.update(26), LegUpdate.keepWalking);
    });

    test('closer, but the same step count once rounded: quiet', () {
      final leg = LegProgress()..reset(80); // about 110 steps
      expect(leg.update(76), LegUpdate.quiet); // still about 110
      expect(leg.update(70), LegUpdate.stepsAhead); // 100
    });

    test('no change: keep walking', () {
      final leg = LegProgress()..reset(40);
      expect(leg.update(39), LegUpdate.keepWalking);
      expect(leg.update(43), LegUpdate.keepWalking);
    });

    test('5 m farther: away, measured from there afterwards', () {
      final leg = LegProgress()..reset(40);
      expect(leg.update(45), LegUpdate.away);
      expect(leg.update(48), LegUpdate.keepWalking);
      expect(leg.update(50), LegUpdate.away);
    });

    test('after reset(null), the next one speaks whatever the distance', () {
      final leg = LegProgress()..reset(null);
      expect(leg.update(80), LegUpdate.stepsAhead);
    });
  });
}

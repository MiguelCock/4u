import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/floor_steps.dart';

void main() {
  test('no change while the next waypoint is on the same floor', () {
    expect(floorChangeAfter([0, 0, 1], 0), isNull);
  });

  test('one hop', () {
    expect(floorChangeAfter([0, 0, 1, 1], 1), (lastIndex: 2, floor: 1));
  });

  test('consecutive hops are one step', () {
    expect(floorChangeAfter([0, 1, 2, 3, 3], 0), (lastIndex: 3, floor: 3));
  });

  test('going down', () {
    expect(floorChangeAfter([2, 1, 1], 0), (lastIndex: 1, floor: 1));
  });

  test('the route ending on the new floor', () {
    expect(floorChangeAfter([0, 1], 0), (lastIndex: 1, floor: 1));
  });

  test('nothing after the last waypoint', () {
    expect(floorChangeAfter([0, 1], 1), isNull);
    expect(floorChangeAfter([], 0), isNull);
  });
}

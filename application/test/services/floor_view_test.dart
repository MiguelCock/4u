import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/floor_view.dart';

void main() {
  Map<String, dynamic> at(int? floor) => {'floor': floor};

  test('floors are listed once, lowest first; a missing floor is 0', () {
    expect(floorsOf([at(2), at(null), at(0), at(2)]), [0, 2]);
  });

  test('the selected floor stays within the range of the points', () {
    expect(floorInRange(4, [0, 1, 2]), 2);
    expect(floorInRange(0, [2]), 2);
    expect(floorInRange(1, [0, 3]), 1);
    expect(floorInRange(1, []), isNull);
  });

  test('a map opens on the ground floor, else its lowest', () {
    expect(openingFloor([0, 1]), 0);
    expect(openingFloor([2, 3]), 2);
    expect(openingFloor([]), isNull);
  });

  group('floorRelation', () {
    test('shows the selected floor and the ones directly next to it', () {
      expect(floorRelation(at(2), 2), FloorRelation.current);
      expect(floorRelation(at(3), 2), FloorRelation.above);
      expect(floorRelation(at(1), 2), FloorRelation.below);
      expect(floorRelation(at(4), 2), FloorRelation.hidden);
      expect(floorRelation(at(0), 2), FloorRelation.hidden);
    });

    test('only the selected floor when asked', () {
      expect(
        floorRelation(at(2), 2, onlySelected: true),
        FloorRelation.current,
      );
      expect(floorRelation(at(3), 2, onlySelected: true), FloorRelation.hidden);
      expect(floorRelation(at(1), 2, onlySelected: true), FloorRelation.hidden);
    });
  });

  group('floorShowsConnection', () {
    test('a corridor on the selected floor, and stairs leaving it', () {
      expect(floorShowsConnection(at(1), at(1), 1), isTrue);
      expect(floorShowsConnection(at(1), at(2), 1), isTrue);
    });

    test('not a corridor on another floor', () {
      expect(floorShowsConnection(at(2), at(2), 1), isFalse);
      expect(floorShowsConnection(at(0), at(2), 1), isFalse);
    });

    test('not stairs leaving the floor when only it is shown', () {
      expect(
        floorShowsConnection(at(1), at(2), 1, onlySelected: true),
        isFalse,
      );
      expect(floorShowsConnection(at(1), at(1), 1, onlySelected: true), isTrue);
    });
  });
}

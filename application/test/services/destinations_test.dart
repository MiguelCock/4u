import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/destinations.dart';

void main() {
  test('important types require a description, in-between ones do not', () {
    expect(descriptionRequiredFor(5), isTrue); // classroom
    expect(descriptionRequiredFor(7), isTrue); // restroom
    expect(descriptionRequiredFor(10), isFalse); // hallway
    expect(descriptionRequiredFor(2), isFalse); // intersection
    expect(descriptionRequiredFor(null), isFalse);
  });

  test('only named points of an important type are destinations', () {
    expect(
      isDestinationAnchor({
        'location_type_id': 8,
        'location_description': 'Cafeteria',
      }),
      isTrue,
    );
    expect(
      isDestinationAnchor({
        'location_type_id': 8,
        'location_description': '  ',
      }),
      isFalse,
    );
    expect(
      isDestinationAnchor({
        'location_type_id': 10,
        'location_description': 'Main hallway',
      }),
      isFalse,
    );
    expect(isDestinationAnchor({'location_type_id': null}), isFalse);
  });

  test('inactive buildings and universities are hidden from users', () {
    final places = [
      {'id': 'u1'},
      {'id': 'u2', 'is_active': false},
    ];
    final buildings = [
      {'id': 'b1', 'place_id': 'u1'},
      {'id': 'b2', 'place_id': 'u1', 'is_active': false},
      {'id': 'b3', 'place_id': 'u2'},
    ];
    expect(activeBuildingIds(places, buildings), {'b1'});
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/api_service.dart';
import 'package:eyes4u/services/map_sync.dart';

MapLists _lists({
  List<Map<String, dynamic>> points = const [],
  List<Map<String, dynamic>> photos = const [],
  List<Map<String, dynamic>> buildings = const [],
}) => MapLists(
  places: const [],
  buildings: buildings,
  anchorPoints: points,
  photos: photos,
  connections: const [],
);

void main() {
  group('applyChanges', () {
    test('replaces changed rows, adds new ones and drops deleted ones', () {
      final lists = _lists(
        points: [
          {'id': 'a', 'updated_at': '1', 'floor': 0},
          {'id': 'b', 'updated_at': '1'},
        ],
      );
      final result = applyChanges(lists, {
        'anchor_points': [
          {'id': 'a', 'updated_at': '2', 'floor': 1},
          {'id': 'c', 'updated_at': '2'},
        ],
        'deleted': {
          'anchor_points': ['b'],
        },
      });
      expect(result.lists.anchorPoints, [
        {'id': 'a', 'updated_at': '2', 'floor': 1},
        {'id': 'c', 'updated_at': '2'},
      ]);
      expect(result.newChanges, 3);
    });

    test(
      'merging the same answer again changes nothing and counts nothing',
      () {
        final changes = {
          'anchor_points': [
            {'id': 'a', 'updated_at': '2'},
          ],
          'deleted': {
            'anchor_point_photos': ['p1'],
          },
        };
        final once = applyChanges(
          _lists(
            points: [
              {'id': 'a', 'updated_at': '1'},
            ],
            photos: [
              {'id': 'p1'},
            ],
          ),
          changes,
        );
        final twice = applyChanges(once.lists, changes);
        expect(twice.lists.anchorPoints, once.lists.anchorPoints);
        expect(twice.lists.photos, isEmpty);
        expect(twice.newChanges, 0);
      },
    );

    test('a deleted building takes its points and photos with it', () {
      final result = applyChanges(
        _lists(
          buildings: [
            {'id': 'b1'},
          ],
          points: [
            {'id': 'a'},
          ],
          photos: [
            {'id': 'p1'},
            {'id': 'p2'},
          ],
        ),
        {
          'deleted': {
            'buildings': ['b1'],
            'anchor_points': ['a'],
            'anchor_point_photos': ['p1', 'p2'],
          },
        },
      );
      expect(result.lists.buildings, isEmpty);
      expect(result.lists.anchorPoints, isEmpty);
      expect(result.lists.photos, isEmpty);
      expect(result.newChanges, 4);
    });

    test('an empty answer leaves everything as it was', () {
      final lists = _lists(
        points: [
          {'id': 'a'},
        ],
      );
      final result = applyChanges(lists, {});
      expect(result.lists.anchorPoints, lists.anchorPoints);
      expect(result.newChanges, 0);
    });
  });

  group('saving only what changed', () {
    final original = {
      'location_description': 'Front door',
      'latitude': 6.2401,
      'floor': 0,
      'metadata': {'indoor': true, 'lighting': null},
    };

    test('only edited fields are sent, with what they were', () {
      final edited = {
        'location_description': 'Front door',
        'latitude': 6.2402,
        'floor': 0,
        'metadata': {'indoor': true, 'lighting': null},
      };
      final changes = changedFields(original, edited);
      expect(changes, {'latitude': 6.2402});
      expect(expectedFor(original, changes), {'latitude': 6.2401});
    });

    test('an integer and a double that are equal count as unchanged', () {
      expect(changedFields({'latitude': 6}, {'latitude': 6.0}), isEmpty);
    });

    test('a changed metadata value is a change', () {
      final changes = changedFields(original, {
        'metadata': {'indoor': false, 'lighting': null},
      });
      expect(changes.keys, ['metadata']);
    });
  });

  group('MapConflict', () {
    test('reads the 409 the backend sends', () {
      final conflict = MapConflict.of(
        ApiException(
          409,
          jsonEncode({
            'detail': {
              'message': 'Another admin changed this point.',
              'fields': ['location_description'],
              'current': {'id': 'a', 'location_description': 'Main door'},
            },
          }),
        ),
      );
      expect(conflict!.fields, ['location_description']);
      expect(conflict.current['location_description'], 'Main door');
    });

    test('other errors, including a plain 409, are not conflicts', () {
      expect(MapConflict.of(ApiException(500, '{}')), isNull);
      expect(
        MapConflict.of(
          ApiException(409, jsonEncode({'detail': 'Already exists'})),
        ),
        isNull,
      );
    });
  });
}

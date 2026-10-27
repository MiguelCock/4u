import 'package:eyes4u/services/anchor_indexing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final points = [
    {'id': 'a', 'status': 'verified'},
    {'id': 'b', 'status': 'verified'},
    {'id': 'c', 'status': 'pending'},
    {'id': 'd', 'status': 'verified'},
  ];
  final photos = {
    'a': [
      {'id': 'a1'},
      {'id': 'a2'},
    ],
    'b': [
      {'id': 'b1'},
    ],
    'c': [
      {'id': 'c1'},
    ],
    'd': <Map<String, dynamic>>[],
  };
  List<Map<String, dynamic>> photosOf(String id) => photos[id]!;

  test('only verified points with an unindexed photo', () {
    final missing = pointsMissingFromIndex(points, photosOf, {'a1', 'b1'});
    expect(missing.map((p) => p['id']), ['a']);
    expect(unsearchablePhotoCount(points, photosOf, {'a1', 'b1'}), 1);
  });

  test('every verified point with photos when the index is unknown', () {
    final missing = pointsMissingFromIndex(points, photosOf, null);
    expect(missing.map((p) => p['id']), ['a', 'b']);
  });

  test('nothing when all is indexed', () {
    expect(
      pointsMissingFromIndex(points, photosOf, {'a1', 'a2', 'b1'}),
      isEmpty,
    );
    expect(unsearchablePhotoCount(points, photosOf, {'a1', 'a2', 'b1'}), 0);
  });
}

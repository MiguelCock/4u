import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/connection_filters.dart';

/// A point [metres] north of the first one, on [floor].
Map<String, dynamic> _point(String id, double metres, {int floor = 0}) => {
  'id': id,
  'floor': floor,
  'latitude': 6.2 + metres / 111320,
  'longitude': -75.58,
};

final _byId = {
  for (final p in [
    _point('a', 0),
    _point('b', 10),
    _point('c', 20),
    _point('up', 2, floor: 1),
  ])
    p['id'] as String: p,
};

Map<String, dynamic> _line(String id, String a, String b, {Object? extra}) => {
  'id': id,
  'anchor_point_a_id': a,
  'anchor_point_b_id': b,
  ...?(extra as Map<String, dynamic>?),
};

final _short = _line('short', 'a', 'b');
final _long = _line('long', 'a', 'c', extra: {'notes': ' Tres escalones '});
final _typed = _line('typed', 'a', 'b', extra: {'distance_meters': 18.0});
final _stairs = _line('stairs', 'a', 'up', extra: {'notes': '  '});
final _all = [_short, _long, _typed, _stairs];

List<String> _ids(ConnectionFilters f) => [
  for (final c in _all)
    if (f.matches(c, _byId)) c['id'] as String,
];

void main() {
  test('no filters keep everything', () {
    expect(_ids(ConnectionFilters.none), ['short', 'long', 'typed', 'stairs']);
    expect(ConnectionFilters.none.isEmpty, isTrue);
  });

  test('over 15 m: the stored distance first, else the straight line', () {
    expect(_ids(const ConnectionFilters(long: true)), ['long', 'typed']);
    expect(_ids(const ConnectionFilters(long: false)), ['short', 'stairs']);
  });

  test('a warning counts only when it has text', () {
    expect(_ids(const ConnectionFilters(hasWarning: true)), ['long']);
    expect(_ids(const ConnectionFilters(hasWarning: false)), [
      'short',
      'typed',
      'stairs',
    ]);
  });

  test('changes floor, and filters combine', () {
    expect(_ids(const ConnectionFilters(changesFloor: true)), ['stairs']);
    const both = ConnectionFilters(long: false, changesFloor: false);
    expect(_ids(both), ['short']);
    expect(both.activeCount, 2);
    expect(both.copyWith(long: null).activeCount, 1);
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/capture_checks.dart';
import 'package:eyes4u/services/connect_chain.dart';

/// A point [metres] north of the first one, on [floor].
Map<String, dynamic> _point(
  String id,
  double metres, {
  int floor = 0,
  int type = 1,
}) => {
  'id': id,
  'floor': floor,
  'location_type_id': type,
  'latitude': 6.2 + metres / 111320,
  'longitude': -75.58,
};

final _a = _point('a', 0);
final _b = _point('b', 10);
final _long = _point('long', 20);
final _far = _point('far', 40);
final _upstairs = _point('up', 2, floor: 1);
final _stairs = _point('stairs', 2, floor: 1, type: 4);
final _byId = {
  for (final p in [_a, _b, _long, _far, _upstairs, _stairs])
    p['id'] as String: p,
};

ConnectStep _tap(
  String? selected,
  Map<String, dynamic> tapped, {
  List<Map<String, dynamic>> connections = const [],
}) => connectTap(
  selectedId: selected,
  tapped: tapped,
  connections: connections,
  pointsById: _byId,
);

void main() {
  test('the first tap selects, the same point again lets go', () {
    expect((_tap(null, _a) as ConnectSelect).id, 'a');
    expect(_tap('a', _a), isA<ConnectDeselect>());
  });

  test('a near point connects, and short ones are not long', () {
    final pair = _tap('a', _b) as ConnectPair;
    expect((pair.fromId, pair.toId), ('a', 'b'));
    expect(pair.distance, closeTo(10, 0.1));
    expect(pair.long, isFalse);
  });

  test('over 15 m connects, but is long', () {
    expect((_tap('a', _long) as ConnectPair).long, isTrue);
  });

  test('an existing pair, either way round or still saving, moves on', () {
    final saved = {'anchor_point_a_id': 'b', 'anchor_point_b_id': 'a'};
    final pending = {
      'anchor_point_a_id': 'a',
      'anchor_point_b_id': 'b',
      'pending': true,
    };
    expect((_tap('a', _b, connections: [saved]) as ConnectMoveOn).id, 'b');
    expect(_tap('a', _b, connections: [pending]), isA<ConnectMoveOn>());
  });

  test('too far or a floor change without stairs is refused', () {
    final far = _tap('a', _far) as ConnectRefused;
    expect(far.problem, ConnectionProblem.tooLong);
    expect(far.distance, closeTo(40, 0.1));
    expect(
      (_tap('a', _upstairs) as ConnectRefused).problem,
      ConnectionProblem.floorChange,
    );
  });

  test('another floor through stairs connects', () {
    expect(_tap('a', _stairs), isA<ConnectPair>());
  });

  test('the pair key is the same either way round', () {
    expect(connectionPairKey('a', 'b'), connectionPairKey('b', 'a'));
  });
}

import 'package:eyes4u/services/admin_lists.dart';
import 'package:flutter_test/flutter_test.dart';

// Two universities; p1 has b1 (two points) and b2 (one), p2 has b3 (one).
final _lists = AdminLists(
  places: [
    {'id': 'p1', 'name': 'Icesi'},
    {'id': 'p2', 'name': 'Javeriana'},
  ],
  buildings: [
    {'id': 'b1', 'place_id': 'p1', 'name': 'Bloque B', 'floors': 3},
    {'id': 'b2', 'place_id': 'p1', 'name': 'Bloque A'},
    {'id': 'b3', 'place_id': 'p2', 'name': 'Central', 'floors': 5},
  ],
  anchorPoints: [
    {'id': 'a1', 'building_id': 'b1'},
    {'id': 'a2', 'building_id': 'b1'},
    {'id': 'a3', 'building_id': 'b2'},
    {'id': 'a4', 'building_id': 'b3'},
  ],
  photos: [
    {'id': 'ph1', 'anchor_point_id': 'a1'},
    {'id': 'ph2', 'anchor_point_id': 'a1'},
    {'id': 'ph3', 'anchor_point_id': 'a4'},
  ],
  connections: [
    {'id': 'c1', 'anchor_point_a_id': 'a1', 'anchor_point_b_id': 'a2'},
    {'id': 'c2', 'anchor_point_a_id': 'a2', 'anchor_point_b_id': 'a3'},
    {'id': 'c3', 'anchor_point_a_id': 'a3', 'anchor_point_b_id': 'a4'},
    {
      'id': 'tmp',
      'anchor_point_a_id': 'a1',
      'anchor_point_b_id': 'a4',
      'pending': true,
    },
  ],
);

List<String> _ids(Iterable<Map<String, dynamic>> rows) => [
  for (final r in rows) r['id'] as String,
];

void main() {
  test('who belongs to whom', () {
    expect(_ids(_lists.buildingsOf('p1')), ['b1', 'b2']);
    expect(_ids(_lists.anchorPointsOf('b1')), ['a1', 'a2']);
    expect(_ids(_lists.photosOf('a1')), ['ph1', 'ph2']);
    expect(_ids(_lists.connectionsOf('a3')), ['c2', 'c3']);
  });

  test('points with photos, and connected points', () {
    expect(_lists.pointsWithPhotos, {'a1', 'a4'});
    expect(_lists.connectedPoints, {'a1', 'a2', 'a3', 'a4'});
  });

  test('a university\'s delete takes its buildings, points and the rest', () {
    final c = _lists.placeCascade('p1');
    expect(_ids(c.buildings), ['b1', 'b2']);
    expect(_ids(c.anchors), ['a1', 'a2', 'a3']);
    expect(c.photos, 2);
    // c3 and the pending one leave p1 too: a delete takes them all.
    expect(c.connections, 4);
  });

  test('a building\'s delete', () {
    final c = _lists.buildingCascade('b2');
    expect(c.buildings, isEmpty);
    expect(_ids(c.anchors), ['a3']);
    expect(c.photos, 0);
    expect(c.connections, 2);
  });

  test('the floors offered: the building\'s, else the most of any', () {
    expect(_lists.maxFloors('b1'), 3);
    expect(_lists.maxFloors('b2'), 1);
    expect(_lists.maxFloors(null), 5);
    expect(_lists.maxFloors('gone'), 5);
    expect(const AdminLists().maxFloors(null), 1);
  });

  test('connections with an end inside, saved ones only', () {
    expect(_ids(_lists.connectionsInScope()), ['c1', 'c2', 'c3']);
    expect(_ids(_lists.connectionsInScope(placeId: 'p2')), ['c3']);
    expect(_ids(_lists.connectionsInScope(placeId: 'p1')), ['c1', 'c2', 'c3']);
    expect(_ids(_lists.connectionsInScope(placeId: 'p2', buildingId: 'b2')), [
      'c2',
      'c3',
    ]);
  });

  test('rows by name: filtered, scoped and sorted', () {
    expect(_ids(rowsByName(_lists.buildings, '')), ['b2', 'b1', 'b3']);
    expect(_ids(rowsByName(_lists.buildings, 'bloque', placeId: 'p1')), [
      'b2',
      'b1',
    ]);
    expect(_ids(rowsByName(_lists.buildings, 'bloque', placeId: 'p2')), []);
  });

  group('back', () {
    AdminBack back({
      bool onMap = false,
      bool onPoints = false,
      bool moving = false,
      bool pointSelected = false,
      bool connecting = false,
      bool pointFilters = false,
      bool scoped = false,
      bool history = false,
      bool drillDown = false,
    }) => adminBack(
      onMap: onMap,
      onPoints: onPoints,
      moving: moving,
      pointSelected: pointSelected,
      connecting: connecting,
      pointFilters: pointFilters,
      scoped: scoped,
      history: history,
      drillDown: drillDown,
    );

    test('on the map: move, selection, Connect, filters, level, in order', () {
      expect(
        back(onMap: true, moving: true, pointSelected: true, history: true),
        AdminBack.cancelMove,
      );
      expect(
        back(onMap: true, pointSelected: true, connecting: true),
        AdminBack.releaseSelection,
      );
      expect(
        back(onMap: true, connecting: true, pointFilters: true),
        AdminBack.leaveConnect,
      );
      expect(
        back(onMap: true, pointFilters: true, scoped: true),
        AdminBack.clearPointFilters,
      );
      expect(back(onMap: true, scoped: true, history: true), AdminBack.levelUp);
      expect(back(onMap: true, history: true), AdminBack.previousTab);
      expect(back(onMap: true), AdminBack.exitGuard);
    });

    test('elsewhere: filters, the tab before, the drill-down, the map', () {
      expect(
        back(onPoints: true, pointFilters: true, history: true),
        AdminBack.clearPointFilters,
      );
      // A move or Connect only counts on the map.
      expect(back(moving: true, connecting: true), AdminBack.toMap);
      expect(back(history: true, drillDown: true), AdminBack.previousTab);
      expect(back(drillDown: true), AdminBack.clearDrillDown);
      expect(back(), AdminBack.toMap);
    });
  });
}

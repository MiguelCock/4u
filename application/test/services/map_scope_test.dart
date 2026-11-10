import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/map_scope.dart';

final _places = [
  {'id': 'eafit', 'name': 'EAFIT', 'code': 'EAF'},
  {'id': 'icesi', 'name': 'Icesi', 'code': 'ICE'},
];
final _buildings = [
  {'id': 'bib', 'place_id': 'eafit', 'name': 'Biblioteca', 'code': 'B'},
  {'id': 'b38', 'place_id': 'eafit', 'name': 'Bloque 38', 'code': '38'},
  {'id': 'ice-bib', 'place_id': 'icesi', 'name': 'Biblioteca Icesi'},
];
final _points = [
  {'id': 'p1', 'building_id': 'bib', 'location_description': 'Entrada sur'},
  {'id': 'p2', 'building_id': 'b38', 'location_description': 'Cafetería'},
];

List<MapSearchResult> _search(String query) => searchMap(
  query,
  places: _places,
  buildings: _buildings,
  points: _points,
  pointName: (p) => p['location_description'] as String,
);

void main() {
  group('MapScope', () {
    test('goes up from a building to its university, then to everything', () {
      final scope = MapScope.building(_buildings.first);
      expect(scope, const MapScope(placeId: 'eafit', buildingId: 'bib'));
      expect(scope.up, const MapScope(placeId: 'eafit'));
      expect(scope.up.up, MapScope.all);
      expect(scope.up.up.isAll, isTrue);
    });

    test(
      'a deleted building or university falls back to what still exists',
      () {
        const scope = MapScope(placeId: 'eafit', buildingId: 'gone');
        expect(
          scope.existingIn(placeIds: {'eafit'}, buildingIds: {}),
          const MapScope(placeId: 'eafit'),
        );
        expect(scope.existingIn(placeIds: {}, buildingIds: {}), MapScope.all);
        expect(
          scope.existingIn(placeIds: {'eafit'}, buildingIds: {'gone'}),
          scope,
        );
      },
    );
  });

  group('searchMap', () {
    test('finds all three kinds, ignoring accents and case', () {
      expect(_search('cafeteria').single.item['id'], 'p2');
      expect(_search('EAF').single.kind, MapSearchKind.place);
    });

    test('a point matches by its building, and says where it is', () {
      final result = _search('entrada biblioteca').single;
      expect(result.item['id'], 'p1');
      expect(result.subtitle, 'Biblioteca · EAFIT');
    });

    test('whole names first, then names that start with it', () {
      final titles = [for (final r in _search('biblioteca')) r.title];
      expect(titles.take(2), ['Biblioteca', 'Biblioteca Icesi']);
      // The point inside matches through its building, after both.
      expect(titles.last, 'Entrada sur');
    });

    test('nothing for an empty query', () {
      expect(_search('  '), isEmpty);
      expect(_search('zzz'), isEmpty);
    });
  });
}

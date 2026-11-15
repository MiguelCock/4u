import 'package:eyes4u/services/spoken_destination.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _building(
  String id,
  String name, {
  String place = 'p1',
  bool active = true,
}) => {
  'id': id,
  'place_id': place,
  'name': name,
  'is_active': active,
  'latitude': 6.2,
  'longitude': -75.58,
};

Map<String, dynamic> _point(
  String id,
  String name, {
  String building = 'b1',
  int type = 8, // cafeteria
  int floor = 0,
}) => {
  'id': id,
  'building_id': building,
  'location_type_id': type,
  'location_description': name,
  'floor': floor,
};

final _buildings = [
  _building('b1', 'Edificio C'),
  _building('b2', 'Cafetería central'),
  _building('b3', 'Edificio C', place: 'p2'), // another campus
  _building('b4', 'Edificio D', active: false),
];
const _names = {
  'b1': 'Edificio C',
  'b2': 'Cafetería central',
  'b3': 'Edificio C',
  'b4': 'Edificio D',
};

List<Map<String, dynamic>> _resolve(
  String heard,
  List<Map<String, dynamic>> points, {
  Map<String, double> meters = const {},
}) {
  final buildings = campusBuildings(_buildings, startBuildingId: 'b1');
  return resolveSpokenDestination(
    heard,
    candidates: destinationCandidates(points, buildings: buildings),
    buildings: buildings,
    buildingNames: _names,
    distance: (a) => meters[a['id']] ?? double.infinity,
  );
}

void main() {
  group('campusBuildings', () {
    test('only active buildings on the start\'s campus', () {
      final ids = campusBuildings(
        _buildings,
        startBuildingId: 'b1',
      ).map((b) => b['id']);
      expect(ids, ['b1', 'b2']);
    });

    test('no start yet: every active building', () {
      final ids = campusBuildings(_buildings).map((b) => b['id']);
      expect(ids, ['b1', 'b2', 'b3']);
    });

    test('the loaded active set wins over a building\'s own flag', () {
      final ids = campusBuildings(
        _buildings,
        activeIds: {'b2'},
        startBuildingId: 'b1',
      ).map((b) => b['id']);
      expect(ids, ['b2']);
    });
  });

  test('destinationCandidates: named destinations, not the start', () {
    final points = [
      _point('a1', 'Cafetería'),
      _point('a2', 'Biblioteca', type: 23),
      _point('a3', '', type: 2), // an unnamed hallway
      _point('a4', 'Pasillo', type: 2), // a named hallway is still hidden
      _point('a5', 'Baño', building: 'b3'), // another campus
    ];
    final ids = destinationCandidates(
      points,
      buildings: campusBuildings(_buildings, startBuildingId: 'b1'),
      startId: 'a2',
    ).map((a) => a['id']);
    expect(ids, ['a1']);
  });

  group('destinationLabel', () {
    String label(Map<String, dynamic> anchor) => destinationLabel(
      anchor,
      buildingNames: _names,
      floorLabel: (floor) => 'Piso ${floor + 1}',
    );

    test('name and building on the ground floor', () {
      expect(label(_point('a1', 'Baño')), 'Baño · Edificio C');
    });

    test('the floor above the ground floor', () {
      expect(
        label(_point('a1', 'Baño', floor: 1)),
        'Baño · Piso 2 · Edificio C',
      );
    });

    test('a whole building is its name', () {
      expect(label(wholeBuilding(_buildings.first)), 'Edificio C');
    });

    test('read aloud with commas', () {
      expect(
        spokenLabel('Baño · Piso 2 · Edificio C'),
        'Baño, Piso 2, Edificio C',
      );
    });
  });

  group('resolveSpokenDestination', () {
    test('a place named exactly that beats a building of the same name', () {
      final found = _resolve('cafetería central', [
        _point('a1', 'Cafetería central'),
      ]);
      expect(found.map((a) => a['id']), ['a1']);
    });

    test('naming only a building means the whole building', () {
      final found = _resolve('edificio c', [_point('a1', 'Baño')]);
      expect(found, hasLength(1));
      expect(found.single['whole_building'], isTrue);
      expect(found.single['building_id'], 'b1');
      expect(found.single['id'], 'building:b1');
    });

    test('saying more than the building is a place in it', () {
      final found = _resolve('baño edificio c', [
        _point('a1', 'Baño'),
        _point('a2', 'Cafetería'),
      ]);
      expect(found.map((a) => a['id']), ['a1']);
    });

    test('same-named places are offered nearest first', () {
      final found = _resolve(
        'baño',
        [_point('a1', 'Baño', floor: 2), _point('a2', 'Baño')],
        meters: {'a1': 40, 'a2': 10},
      );
      expect(found.map((a) => a['id']), ['a2', 'a1']);
    });

    test('nothing it knows: nothing', () {
      expect(_resolve('el acuario', [_point('a1', 'Baño')]), isEmpty);
    });

    test('a clear winner comes alone', () {
      final found = _resolve('quiero ir a la biblioteca', [
        _point('a1', 'Biblioteca', type: 23),
        _point('a2', 'Cafetería'),
      ]);
      expect(found.map((a) => a['id']), ['a1']);
    });
  });
}

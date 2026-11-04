import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/destination_matcher.dart';

void main() {
  final cafeteria13 = {
    'id': 'c13',
    'building_id': 'b13',
    'location_description': 'Cafetería',
  };
  final cafeteria38 = {
    'id': 'c38',
    'building_id': 'b38',
    'location_description': 'Cafetería',
  };
  final room301 = {
    'id': 'r301',
    'building_id': 'b13',
    'location_description': 'Salón 301',
  };
  final room302 = {
    'id': 'r302',
    'building_id': 'b13',
    'location_description': 'Salón 302',
  };
  final restroom = {
    'id': 'wc',
    'building_id': 'b13',
    'location_description': 'Main restroom',
  };
  const buildings = {'b13': 'Bloque 13', 'b38': 'Bloque 38'};

  test('normalizes accents, case and punctuation', () {
    expect(normalizeForMatch('¡Cafetería, Bloque-13!'), 'cafeteria bloque 13');
  });

  test('a natural Spanish sentence finds the place', () {
    final matches = matchDestinations('quiero ir al salón 301', [
      room301,
      room302,
      restroom,
    ], buildingNames: buildings);
    expect(clearWinner(matches)?.anchor['id'], 'r301');
  });

  test('numbers must match exactly', () {
    final matches = matchDestinations('salon 303', [room301, room302]);
    expect(matches.every((m) => m.score < 1), isTrue);
    expect(clearWinner(matches), isNull);
  });

  test('accents and partial words still match', () {
    final matches = matchDestinations('take me to the cafe', [
      cafeteria13,
      restroom,
    ]);
    expect(clearWinner(matches)?.anchor['id'], 'c13');
  });

  test('two equally good places are ambiguous', () {
    final matches = matchDestinations('cafeteria', [cafeteria13, cafeteria38]);
    expect(matches, hasLength(2));
    expect(clearWinner(matches), isNull);
  });

  test('the building name disambiguates', () {
    final matches = matchDestinations('cafetería del bloque 38', [
      cafeteria13,
      cafeteria38,
    ], buildingNames: buildings);
    expect(clearWinner(matches)?.anchor['id'], 'c38');
  });

  test('naming only a building chooses nothing', () {
    expect(
      matchDestinations('bloque 13', [
        cafeteria13,
        room301,
      ], buildingNames: buildings),
      isEmpty,
    );
  });

  test('unrelated speech matches nothing', () {
    expect(matchDestinations('library', [cafeteria13, restroom]), isEmpty);
    expect(matchDestinations('', [cafeteria13]), isEmpty);
  });

  group('buildings (Icesi, 2026-11-04)', () {
    Map<String, dynamic> building(String id, String name, [String? code]) => {
      'id': id,
      'name': name,
      'code': code ?? name,
    };
    final icesi = [
      building('a', 'Edificio A'),
      building('b', 'Edificio B - Saman', 'B - Saman'),
      building('c', 'Edificio C'),
      building('d', 'Edificio D'),
      building('i', 'Bienestar Universitario - Edificio I', 'Edificio H'),
      building('h', 'Edificio H Smurfit Kappa'),
      building('n', 'Edificio N - Ingenierías'),
      building('c1', 'coliseo 1'),
      building('c2', 'coliseo 2'),
      building('lib', 'Edificio Biblioteca Universidad Icesi'),
    ];
    String? winner(String spoken) =>
        clearWinner(matchBuildings(spoken, icesi))?.anchor['id'] as String?;

    test('a building by its letter, however it was heard', () {
      expect(winner('Edificio C'), 'c');
      expect(winner('edificio se'), 'c');
      expect(winner('edificio ce'), 'c');
      expect(winner('quiero ir al edificio ene'), 'n');
      expect(winner('edificio n por favor'), 'n');
    });

    test('letters that are also stop words', () {
      expect(winner('Edificio A'), 'a');
      expect(winner('edificio de'), 'd');
      expect(winner('edificio i'), 'i');
    });

    test('B and V are one letter', () {
      expect(winner('edificio ve'), 'b');
      expect(winner('edificio be'), 'b');
    });

    test('the rest of its name, without the letter', () {
      expect(winner('edificio de ingenierias'), 'n');
      expect(winner('biblioteca'), 'lib');
    });

    test('a name wins over another building\'s code', () {
      expect(winner('edificio h'), 'h');
    });

    test('several buildings ask', () {
      final matches = matchBuildings('coliseo', icesi);
      expect(matches, hasLength(2));
      expect(clearWinner(matches), isNull);
    });

    test('only saying "edificio" names none', () {
      expect(matchBuildings('edificio', icesi), isEmpty);
      expect(matchBuildings('', icesi), isEmpty);
    });

    test('a place in a building is not the building', () {
      expect(matchBuildings('baño edificio n', icesi), isEmpty);
    });

    test('"edificio" alone does not suggest places', () {
      final machine = {
        'id': 'm',
        'building_id': 'n',
        'location_description': 'Maquina de pagar parqueadero Edificio N',
      };
      expect(matchDestinations('Edificio C', [machine]), isEmpty);
    });

    test('a place named with its building still works', () {
      final restroom = {
        'id': 'wc',
        'building_id': 'n',
        'location_description': 'Baño Edificio N',
      };
      expect(
        clearWinner(
          matchDestinations('baño edificio n', [restroom]),
        )?.anchor['id'],
        'wc',
      );
    });
  });

  group('names without their building', () {
    final southLibrary = {
      'id': 'lib',
      'building_id': 'l',
      'location_description': 'Entrada sur',
    };
    final south20 = {
      'id': '20',
      'building_id': 'b20',
      'location_description': 'Entrada sur',
    };
    final names = {
      'l': 'Edificio Biblioteca Universidad Icesi',
      'b20': 'Bloque 20',
    };

    test('saying the building picks the right one', () {
      expect(
        clearWinner(
          matchDestinations('entrada sur biblioteca', [
            southLibrary,
            south20,
          ], buildingNames: names),
        )?.anchor['id'],
        'lib',
      );
      expect(
        clearWinner(
          matchDestinations('entrada sur bloque 20', [
            southLibrary,
            south20,
          ], buildingNames: names),
        )?.anchor['id'],
        '20',
      );
    });

    test('the name alone asks, nearest first', () {
      final matches = matchDestinations('entrada sur', [
        southLibrary,
        south20,
      ], buildingNames: names);
      expect(clearWinner(matches), isNull);
      final sorted = nearestFirst(
        matches,
        (anchor) => anchor['id'] == '20' ? 5 : 500,
      );
      expect(sorted.first.anchor['id'], '20');
    });

    test('exact names, alone or with the building', () {
      List<String?> exact(String spoken) => exactPlaces(spoken, [
        southLibrary,
        south20,
      ], buildingNames: names).map((a) => a['id'] as String?).toList();
      expect(exact('entrada sur'), ['lib', '20']);
      expect(exact('entrada sur bloque 20'), ['20']);
      expect(exact('entrada'), isEmpty);
      expect(exact(''), isEmpty);
    });
  });
}

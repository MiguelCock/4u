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
}

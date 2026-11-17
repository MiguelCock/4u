import 'package:eyes4u/services/destination_matcher.dart';
import 'package:eyes4u/services/spoken_destination.dart';
import 'package:flutter_test/flutter_test.dart';

/// D13 (#261): people ask in full requests, with connectors and polite
/// words, and for a kind of place rather than its name.

Map<String, dynamic> _point(
  String id,
  String name, {
  String building = 'b1',
  required int type,
}) => {
  'id': id,
  'building_id': building,
  'location_type_id': type,
  'location_description': name,
  'floor': 0,
};

const _restroom = 7, _cafeteria = 8, _library = 23, _infirmary = 27;
const _classroom = 5, _atm = 22;

final _buildings = [
  {'id': 'b1', 'place_id': 'p1', 'name': 'Edificio C', 'is_active': true},
  {'id': 'b2', 'place_id': 'p1', 'name': 'Bloque 20', 'is_active': true},
];
const _names = {'b1': 'Edificio C', 'b2': 'Bloque 20'};

final _points = [
  _point('lib', 'Biblioteca', type: _library),
  _point('wc-c', 'Baño', type: _restroom),
  _point('wc-20', 'Sanitarios', building: 'b2', type: _restroom),
  _point('inf', 'Enfermería', building: 'b2', type: _infirmary),
  _point('caf', 'Cafetería central', type: _cafeteria),
  _point('kiosk', 'Kiosko Juan Valdez', building: 'b2', type: _cafeteria),
  _point('301', 'Salón 301', type: _classroom),
  _point('atm', 'Bancolombia', building: 'b2', type: _atm),
];

/// Meters from where the user stands.
const _meters = {
  'lib': 80.0,
  'wc-c': 120.0,
  'wc-20': 40.0,
  'inf': 60.0,
  'caf': 90.0,
  'kiosk': 30.0,
  '301': 50.0,
  'atm': 70.0,
};

List<String> _ids(String heard) => [
  for (final p in resolveSpokenDestination(
    heard,
    candidates: _points,
    buildings: _buildings,
    buildingNames: _names,
    distance: (a) => _meters[a['id']] ?? double.infinity,
  ))
    p['id'] as String,
];

void main() {
  group('request phrasing is not part of the place', () {
    for (final (heard, id) in [
      ('necesito encontrar la biblioteca', 'lib'),
      ('me puedes llevar donde la enfermería', 'inf'),
      ('me podrías llevar a la enfermería por favor', 'inf'),
      ('quisiera ir a la biblioteca', 'lib'),
      ('busco la biblioteca', 'lib'),
      ('dónde queda la enfermería', 'inf'),
      ('oye llévame a la biblioteca rápido', 'lib'),
      ('hola, necesito llegar al salón 301', '301'),
      ('I need the library', 'lib'),
      ('can you take me to the library please', 'lib'),
      ('how do I get to room 301', '301'),
    ]) {
      test('"$heard"', () => expect(_ids(heard), [id]));
    }
  });

  group('a word for a kind of place finds it, whatever it is called', () {
    test('"baño" offers every restroom, nearest first', () {
      expect(_ids('quiero ir al baño'), [
        'wc-20',
        'wc-c',
      ], reason: 'not only the one called "Baño"');
      expect(_ids('busco un sanitario'), ['wc-20', 'wc-c']);
      expect(_ids('necesito un servicio'), ['wc-20', 'wc-c']);
    });

    test('"comer" and "cajero"', () {
      expect(_ids('dónde puedo comer'), ['kiosk', 'caf']);
      expect(_ids('necesito un cajero'), ['atm']);
    });

    test('plurals', () {
      expect(_ids('los baños'), ['wc-20', 'wc-c']);
    });
  });

  group('"más cercano" picks the nearest of that kind', () {
    for (final (heard, id) in [
      ('quisiera ir al baño más cercano', 'wc-20'),
      ('el baño más cercano', 'wc-20'),
      ('llévame a la cafetería más cercana', 'kiosk'),
      ('the nearest restroom', 'wc-20'),
      ('dónde queda el baño más próximo', 'wc-20'),
    ]) {
      test('"$heard"', () => expect(_ids(heard), [id]));
    }

    test('asksForNearest', () {
      expect(asksForNearest('el baño más cercano'), isTrue);
      expect(asksForNearest('el baño'), isFalse);
    });
  });

  group('still nothing for what names nothing', () {
    test('only polite words', () {
      expect(_ids('me puedes ayudar por favor'), isEmpty);
    });

    test('a kind of place nobody mapped', () {
      expect(_ids('la capilla'), isEmpty);
    });
  });
}

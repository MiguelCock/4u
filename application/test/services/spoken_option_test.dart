import 'package:eyes4u/services/destination_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const options = [
    'Baño · Piso 2 · Biblioteca',
    'Baño · Edificio C',
    'Baño · Cafetería central',
  ];

  test('a number, in words or digits', () {
    expect(pickSpokenOption('el dos', options), 1);
    expect(pickSpokenOption('3', options), 2);
    expect(pickSpokenOption('primero', options), 0);
    expect(pickSpokenOption('the second one', options), 1);
  });

  test('a name only one option has', () {
    expect(pickSpokenOption('el de la biblioteca', options), 0);
    expect(pickSpokenOption('cafetería', options), 2);
  });

  test('what every option shares, or two numbers, is not clear', () {
    expect(pickSpokenOption('baño', options), isNull);
    expect(pickSpokenOption('uno o dos', options), isNull);
    expect(pickSpokenOption('', options), isNull);
    expect(pickSpokenOption('cuatro', options), isNull);
  });

  test('none of them', () {
    expect(pickSpokenOption('ninguno', options), -1);
    expect(pickSpokenOption('no', options), -1);
  });
}

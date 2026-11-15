import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/abbreviation.dart';

void main() {
  test('initials of the name, without the small words (C10)', () {
    expect(abbreviationFor('Universidad Pontificia Bolivariana'), 'UPB');
    expect(abbreviationFor('Universidad de los Andes'), 'UA');
    expect(abbreviationFor('Escuela de Ingeniería de Antioquia'), 'EIA');
    expect(abbreviationFor('University of the Arts'), 'UA');
  });

  test('accents and spacing don\'t matter; nothing gives nothing', () {
    expect(abbreviationFor('  Ícono   Único  '), 'IU');
    expect(abbreviationFor(''), '');
  });
}

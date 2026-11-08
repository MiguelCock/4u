import 'package:eyes4u/services/destination_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('yes in either language starts the route', () {
    for (final heard in [
      'Sí',
      'si, vamos',
      'Empezar',
      'dale',
      'yes',
      'OK start',
    ]) {
      expect(spokenAnswer(heard), SpokenAnswer.start, reason: heard);
    }
  });

  test('no or change asks again', () {
    for (final heard in ['No', 'cambiar destino', 'otro lugar', 'change it']) {
      expect(spokenAnswer(heard), SpokenAnswer.change, reason: heard);
    }
  });

  test('anything else, or both, does nothing', () {
    for (final heard in ['', 'la biblioteca', 'no sé, sí', 'ehh']) {
      expect(spokenAnswer(heard), isNull, reason: heard);
    }
  });
}
